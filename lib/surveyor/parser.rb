%w(survey survey_translation survey_section question_group question dependency dependency_condition answer validation validation_condition).each {|model| require model }

require 'yaml'
require 'lunokhod'
require_relative 'surveyor_backend'

module Surveyor
  class ParserError < StandardError; end
  class Parser
    class << self; attr_accessor :options, :log end

    # Attributes
    attr_accessor :context

    # Class methods
    def self.parse_file(filename, options={})
      self.parse(File.read(filename),{:filename => filename}.merge(options))
    end
    def self.parse(str, options={})
      p  = Lunokhod::Parser.new(str, options[:filename] || "(String)");p.parse
      r  = Lunokhod::Resolver.new(p.surveys).tap{|r|r.run}
      ep = Lunokhod::ErrorReport.new(p.surveys).tap{|ep|ep.run}
      raise Surveyor::ParserError, ep if ep.errors?
      b = Surveyor::Backend.new(options[:filename].nil? ? Dir.pwd : File.dirname(options[:filename]))
      Lunokhod::Compiler.new(p.surveys, b).compile
      b.write
      puts b.surveys.map(&:ar_node).map(&:valid?)
    end
  end
end
