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
# TODO replace display_order with n.qseq
# TODO custom hash builder for CommonOptions instead of merge? w/ making every option explicit
# TODO  in lunokhod: nodes without tags should have n.tag == nil instead of n.tag == ""
# TODO does :display_order really need to be explicitly specifiable?
# TODO attempt to eliminate @scope usage via the ar_node connections
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

# TODO: could do this somewhat automatically for all nodes
module Lunokhod::Ast::AstNode
  attr_accessor :ar_node
end


module Surveyor
  class Backend
    include Lunokhod::Visitation
    include Surveyor::CompilerChecks

    attr_accessor :level
    attr_accessor :surveys
    attr_accessor :dir
    attr_accessor :default_mandatory


    def initialize(dir) # see parser.rb#200
      @dir = dir
      @surveys = []
      @scope = {}
    end

    def write
      @surveys.map(&:ar_node).each(&:save)
    end

    def prologue
    end

    #TODO: support ValidationConditions (when they work in surveyor)
    def epilogue
      @surveys.each do |s|
        visit(s, true) do |n, _, _, _|
          if n.is_a?(Lunokhod::Ast::DependencyCondition)
            n.ar_node.question = n.referenced_question.ar_node
            n.ar_node.answer   = n.referenced_answer.try(:ar_node)
          end
        end
      end
    end

    def survey(n)
      @default_mandatory = n.options.delete(:default_mandatory){false}
      @scope[:survey] = Survey.new({
        :title => n.name,
        :display_order => @surveys.size
      }.merge(n.options))
      n.ar_node = @scope[:survey]
      yield
      @scope.delete(:survey)
      @surveys << n
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
        :display_order => @scope[:survey].sections.size,
        :reference_identifier => n.tag.blank? ? nil : n.tag
      }.merge(n.options))
      yield
      @scope.delete(:section)
    end

    #see parser.rb#245 regarding :display_type
    def group(n)
      group_repeater_grid(@scope)
      @scope[:group] = QuestionGroup.new({
        :text => n.name,
        :display_type => 'default',
        :reference_identifier => n.tag.blank? ? nil : n.tag
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
        :display_type => 'repeater',
        :reference_identifier => n.tag.blank? ? nil : n.tag
      })
      yield
      @scope.delete(:repeater)
    end

    #Lunokhod::AST::Grid does not have options?
    def grid(n)
      group_repeater_grid(@scope)
      @scope[:grid] = QuestionGroup.new({
        :text => n.text,
        :display_type => 'grid',
        :reference_identifier => n.tag.blank? ? nil : n.tag
      })
      yield

      n.questions.each do |q|
        n.answers.each do |a|
          q.ar_node.answers.build(a.ar_node.attributes.reject{|k,v| %w(id api_id created_at updated_at).include?(k)})
        end
      end

      @scope.delete(:grid)
    end

    def label(n)
      @scope[:section].questions << @scope[:label] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        :display_type   => 'label',
        :display_order  => @scope[:section].questions.size,
        #:pick => 'none',
        :reference_identifier => n.tag.blank? ? nil : n.tag
      }.merge(n.options))
      yield
      @scope.delete(:label)
    end

    def question(n)
      @scope[:section].questions << @scope[:question] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        # :display_type   => 'default',
        :display_order  => @scope[:section].questions.size,
        :is_mandatory   => @default_mandatory,
        :reference_identifier => n.tag.blank? ? nil : n.tag
      }.merge(n.options))
      n.ar_node =  @scope[:question]
      yield
      @scope.delete(:question)
    end

    #TODO see parser.rb#parse_args
    #TODO handle :other_and_string? or depricate it
    def answer(n)
      @scope[:answer] = Answer.new({
        :text => answer_text(n),
        :response_class => answer_response_class(n),
        :is_exclusive => answer_is_exclusive(n),
        :reference_identifier => n.tag.blank? ? nil : n.tag,
        :display_order => answer_display_order(n)
      }.merge(n.options))

      if translate(n.parent) == :question
        @scope[:answer].question = @scope[:question]
        @scope[:question].answers << @scope[:answer]
      end

      n.ar_node = @scope[:answer]
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
        :rule_key => n.tag,
        p         => @scope[p]
      }.merge(condition_h(n)))
       .tap{|r| n.ar_node = r}
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

    #TODO: fix lunokhod handling of "a :other" or "a :omit"? maybe better to just depreicate them
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

    #TODO: this can possibly be cleaned up when n.type is adjusted
    def answer_response_class(n)
      if [:date, :datetime, :time, :float, :integer, :string, :text].include? n.type
        n.type
      else
        :answer
      end
    end

    #TODO lunokhod should figure this out and put it in seq?
    def answer_display_order(n)
      return  n.options[:display_order] if !n.options[:display_order].nil?
      case translate(n.parent)
      when :grid
        n.parent.answers.index(n) #TODO: write spec in lunokhod for ordering
      when :question
        @scope[:question].answers.size
      end
    end
  end
end
