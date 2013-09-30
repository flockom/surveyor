%w(survey survey_translation survey_section question_group question dependency dependency_condition answer validation validation_condition).each {|model| require model}

require 'yaml'

# TODO we should probobly use surveyor_tag in here somewhere. make it explicit what :reference_identifier will be.
#      add reference identifier on everything that needs it.
# TODO error reporting for unexpected scopes? certian situations where surveyor is limited but the AST is not
#      e.g. nested groups, dependencies in repeaters, etc
# TODO go through parser and check for any default values
# TODO better errors about groups/grids/repeater nesting
# TODO unify groups/repeaters/grids ?
# TODO check all cases against parse_and_build methods in parser.rb
# TODO replace << with build
# TODO surveyor sets data_export_identifier from the text somewhere
module Surveyor::CompilerChecks
  #TODO do we really want this together? probobly just combine them to one hash point
  def group_repeater_grid(scope)
    [scope[:group], scope[:repeater], scope[:grid]].compact.tap { |grg|
      fail "surveyor does not support nested groups/repeaters/grids" if grg.size > 1
    }.first
  end

  #TODO same as group_repeater_grid
  def question_label(scope)
    [scope[:question], scope[:label]].first
  end

  #put this somewhere else
  def translate(n)
    n.class.name.gsub(/^.*::/,'').downcase.to_sym
  end
end

module Surveyor
  class Backend
    include Surveyor::CompilerChecks
    attr_accessor :level
    attr_accessor :surveys
    attr_accessor :dir
    attr_accessor :default_mandatory


    def initialize(dir) # see parser.rb#200
      @dir = dir
      @surveys = []
      @scope = {}
      @grid_answers = []
      @resolve_map = {}.tap{|h|h.compare_by_identity}
    end

    def write
      @surveys.map(&:save)
    end

    def prologue
    end

    #TODO: support ValidationConditions (when they work in surveyor)
    def epilogue
      @resolve_map
        .select{ |_,v| v.is_a?(DependencyCondition)}
        .each do |(lunokhod_node, ar_node)|
        ar_node.question = @resolve_map[lunokhod_node.referenced_question]
        ar_node.answer = @resolve_map[lunokhod_node.referenced_answer]
      end
    end

    def survey(n)
      @default_mandatory = n.options.delete(:default_mandatory){false}
      @scope[:survey] = Survey.new({:title => n.name}.merge(n.options))
      yield
      @surveys << @scope.delete(:survey)
    end

    # TODO: support inline translations in lunokhod
    # TODO: handle default here
    def translation(n)
      @scope[:survey].translations << SurveyTranslation.new(
        :survey => @scope[:survey],
        :locale => n.lang,
        :translation => File.read(File.join(@dir, n.path)))
      yield
    end

    def section(n)
      @scope[:survey].sections  << @scope[:section] = SurveySection.new({
        :survey => @scope[:survey],
        :title => n.name,
        :display_order => @scope[:survey].sections.size
      }.merge(n.options))
      yield
      @scope.delete(:section)
    end

    #see parser.rb#245 regarding :display_type
    def group(n)
      group_repeater_grid(@scope)
      @scope[:group] = QuestionGroup.new({
        :text => n.name,
        :display_type => 'default'
      }.merge(n.options))
      yield
      @scope.delete(:group)
    end

    #see parser.rb#245 regarding :display_type
    #TODO: repeater does not have options?
    def repeater(n)
      group_repeater_grid(@scope)
      @scope[:repeater] = QuestionGroup.new({
        :text => n.text,
        :display_type => 'repeater'
      })
      yield
      @scope.delete(:repeater)
    end

    #Lunokhod::AST::Grid does not have options?
    def grid(n)
      group_repeater_grid(@scope)
      @scope[:grid] = QuestionGroup.new({
        :text => n.text,
        :display_type => 'grid'
      })
      yield

      @scope[:grid].questions.each do |q|
        @grid_answers.each do |a|
          q.answers.build(a.attributes.reject{|k,v| %w(id api_id created_at updated_at).include?(k)})
        end
      end

      @grid_answers = []
      @scope.delete(:grid)
    end

    def label(n)
      @scope[:section].questions << @scope[:label] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        :display_type   => 'label',
        :display_order  => @scope[:section].questions.size
      }.merge(n.options))
      yield
      @scope.delete(:label)
    end

    def question(n)
      @scope[:section].questions << @scope[:question] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        :display_type   => 'default',
        :display_order  => @scope[:section].questions.size,
        :is_mandatory   => @default_mandatory,
        :reference_identifier => n.tag
      }.merge(n.options))
      @resolve_map[n] = @scope[:question]
      yield
      @scope.delete(:question)
    end

    #TODO see parser.rb#parse_args
    #TODO handle grids
    #TODO handle :other_and_string
    def answer(n)
      @scope[:answer] = Answer.new({
        :text => answer_text(n),
        :response_class => n.type,
        :is_exclusive => answer_is_exclusive(n)
      }.merge(n.options))

      case translate(n.parent)
      when :grid
        @scope[:answer].display_order = @grid_answers.size
        @grid_answers << @scope[:answer]
      when :question
        @scope[:answer].display_order = @scope[:question].answers.size
        @scope[:answer].question = @scope[:question]
        @scope[:question].answers << @scope[:answer]
      end
      @resolve_map[n] = @scope[:answer]
      yield
      @scope.delete(:answer)
    end

    #questions don't have children as groups, thus scope will be empty
    def dependency(n)
      p = translate(n.parent)
      @scope[p].dependency = @scope[:dependency] = Dependency.new({
        :question => [:question, :label].include?(p) ? @scope[p] : nil,
        :question_group => [:group, :repeater, :grid].include?(p) ? @scope[p] : nil,
        :rule => n.rule
      })
      yield
      @scope.delete(:dependency)
    end

    def validation(n)
      @scope[:answer].validations << @scope[:validation] = Validation.new({
        :answer => @scope[:answer],
        :rule => n.rule
      })
      yield
      @scope.delete(:validation)
    end


    # TODO: should we default :operator to "=="? (see parser.rb:348)
    def condition(n)
      p = translate(n.parent)
      type = {:dependency => DependencyCondition, :validation => ValidationCondition}[p]
      @scope[p].send("#{p}_conditions") << type.new({
        :rule_key => n.tag
      }.merge(condition_h(n)))
       .tap{|r| @resolve_map[n] = r}
      yield
    end

    def condition_h(n)
      case n.parsed_condition
        when Lunokhod::ConditionParsing::AnswerSelected
        {:operator => n.parsed_condition.op}
        when Lunokhod::ConditionParsing::AnswerCount
        {:operator => 'count'+n.parsed_condition.op+n.parsed_condition.value.to_s}
        when Lunokhod::ConditionParsing::AnswerSatisfies
        {:operator => n.parsed_condition.op, n.parsed_condition.criterion => n.parsed_condition.value}
        when Lunokhod::ConditionParsing::SelfAnswerSatisfies
        {:operator => n.parsed_condition.op, n.parsed_condition.criterion => n.parsed_condition.value}
      end
    end

    #TODO: fix lunokhod handling of "a :other"? maybe better to just depreicate :other
    #TODO: possibly get rid of :none and :omit
    def answer_text(n)
      return n.text if n.text
      return 'Other' if n.other || n.type == :other
      return n.type.to_s.humanize if [:none, :omit].include?(n.type)
      return 'Answer'
    end

    def answer_is_exclusive(n)
      return [:none, :omit].include?(n.type)
    end

  end
end
