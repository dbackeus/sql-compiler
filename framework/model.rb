require "pg"

class Model
  attr_reader :attributes

  def initialize(attributes)
    @attributes = attributes
  end

  def self.subclasses
    @subclasses ||= []
  end

  def self.inherited(subclass)
    subclasses << subclass
    subclass.extend ClassMethods
  end

  def self.connection
    @connection ||= begin
      PG.connect(dbname: "sql_compiler_development").tap do |connection|
        connection.type_map_for_results = PG::BasicTypeMapForResults.new(connection)
      end
    rescue PG::ConnectionBad => e
      if e.message.include? %(database "sql_compiler_development" does not exist)
        PG.connect(dbname: "postgres").exec("CREATE DATABASE sql_compiler_development")
        retry
      else
        raise
      end
    end
  end

  module ClassMethods
    def attribute(name)
      name = name.to_s

      define_method(name) do
        @attributes[name]
      end

      define_method("#{name}=") do |value|
        @attributes[name] = value
      end
    end

    def table_name
      name.downcase.pluralize
    end

    def all
      connection.exec("SELECT * FROM #{table_name}").map { |attributes| new(attributes) }
    end

    def find(id)
      result = connection.exec("SELECT * FROM #{table_name} WHERE id = #{id} LIMIT 1")
      raise "Record not found" if result.none?

      new(result.first)
    end

    def create(**attributes)
      attributes["created_at"] ||= Time.now
      attributes["updated_at"] ||= Time.now

      columns = attributes.keys.join(", ")
      values = attributes.values.map { |v| "'#{v}'" }.join(", ")

      connection.exec("INSERT INTO #{table_name} (#{columns}) VALUES (#{values})")
    end
  end
end
