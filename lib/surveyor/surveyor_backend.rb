%w(survey survey_translation survey_section question_group question dependency dependency_condition answer validation validation_condition).each {|model| require model}

require 'yaml'

# TODO we should probobly use surveyor_tag in here somewhere
# TODO error reporting for unexpected scopes? certian situations where surveyor is limited but the AST is not
#      e.g. nested groups, dependencies in repeaters, etc
# TODO go through parser and check for any default values
# TODO better errors about groups/grids/repeater nesting
# TODO unify groups/repeaters/grids ?
# TODO check all cases against parse_and_build methods in parser.rb
# TODO replace << with build
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
  def dependency_association(n,scope)
    return :question if [Lunokhod::AST::Question, Lunokhod::AST::Label].any?{|k|n.parent.is_a?(k)}
    return :question_group if [Lunokhod::AST::Group, Lunokhod::AST::Repeater, Lunokhod::AST::Grid].any?{|k|n.parent.is_a?(k)}
  end
end

module Surveyor
  class Backend
    include Surveyor::CompilerChecks
    attr_accessor :level
    attr_accessor :surveys
    attr_accessor :dir


    def initialize(dir) # see parser.rb#200
      @dir = dir
      @surveys = []
      @scope = {}
    end

    def write
      @surveys.map(&:save)
    end

    def prologue
    end

    def epilogue
    end

    def survey(n)
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
    def repeater(n)
      group_repeater_grid(@scope)
      @scope[:repeater] = QuestionGroup.new({
        :text => n.name,
        :display_type => 'repeater'
      }.merge(n.options))
      yield
      @scope.delete(:repeater)
    end

    def grid(n)
      group_repeater_grid(@scope)
      @scope[:grid] = QuestionGroup.new({
        :text => n.name,
        :display_type => 'grid'
      }.merge(n.options))
      yield
      @scope.delete(:grid)
    end

    def label(n)
      @scope[:section].questions << @scope[:labe] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        :display_type   => 'label',
        :display_order  => @scope[:section].questions.size
      }.merge(n.options))
      yield
      @scope.delete(:labe)
    end

    def question(n)
      @scope[:section].questions << @scope[:question] = Question.new({
        :survey_section => @scope[:section],
        :question_group => group_repeater_grid(@scope),
        :text           => n.text,
        :display_type   => 'default',
        :display_order  => @scope[:section].questions.size
      }.merge(n.options))
      yield
      @scope.delete(:question)
    end

    #TODO see parser.rb#parse_args
    #TODO handle grids
    #TODO handle :other,:other_and_string,:none,:omit
    def answer(n)
      @scope[:question].answers << @scope[:answer] = Answer.new({
        :question      => @scope[:question],
        :display_order => @scope[:question].answers.size,
        :text => n.text || 'Answer',
        :response_class => n.type
      }.merge(n.options))
      yield
      @scope.delete(:answer)
    end

    #questions don't have children as groups, thus scope will be empty
    def dependency(n)
      parent = dependency_association
      #@scope[(parent==:question)? ].dependency << @scope[:dependency] =
      yield
    end

    def validation(n)
      yield
    end

    def condition(n)
      yield
    end
  end
end
