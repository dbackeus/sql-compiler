require "pg"

class Model
  attr_reader :attributes

  def initialize(attributes, query_location: nil, loaded_columns: nil)
    @attributes = attributes.transform_keys(&:to_s)
    @query_location = query_location
    @loaded_columns = Array(loaded_columns || @attributes.keys).map(&:to_s)
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

  def read_attribute(name)
    name = name.to_s
    return @attributes[name] if @attributes.key?(name)

    raise MissingProjectedAttributeError.new(
      model_class: self.class,
      attribute_name: name,
      query_location: @query_location,
      loaded_columns: @loaded_columns
    )
  end

  module ClassMethods
    def attribute(name)
      name = name.to_s
      attribute_names << name

      define_method(name) do
        read_attribute(name)
      end

      define_method("#{name}=") do |value|
        @attributes[name] = value
        @loaded_columns |= [name]
      end
    end

    def attribute_names
      @attribute_names ||= []
    end

    def table_name
      name.downcase.pluralize
    end

    def all(select: nil)
      query_location = caller_locations(1, 1).first
      columns = select || compiled_projection_for(:all, query_location)

      exec_sql("SELECT #{projection_clause(columns)} FROM #{table_name}").map do |attributes|
        new(attributes, query_location:, loaded_columns: columns)
      end
    end

    def find(id, select: nil)
      query_location = caller_locations(1, 1).first
      columns = select || compiled_projection_for(:find, query_location)

      result = exec_sql("SELECT #{projection_clause(columns)} FROM #{table_name} WHERE id = #{id} LIMIT 1")
      raise "Record not found" if result.none?

      new(result.first, query_location:, loaded_columns: columns)
    end

    def exec_sql(sql)
      blue = "\e[34m"
      reset = "\e[0m"
      puts "EXECUTING SQL: #{blue}#{sql}#{reset}"
      connection.exec(sql)
    end

    def create(**attributes)
      attributes["created_at"] ||= Time.now
      attributes["updated_at"] ||= Time.now

      columns = attributes.keys.join(", ")
      values = attributes.values.map { |v| "'#{v}'" }.join(", ")

      exec_sql("INSERT INTO #{table_name} (#{columns}) VALUES (#{values})")
    end

    private

    def compiled_projection_for(query_kind, query_location)
      return unless query_location

      ProjectionRegistry.lookup(
        path: query_location.path,
        line: query_location.lineno,
        model_class: self,
        query_kind:
      )
    end

    def projection_clause(columns)
      return "*" unless columns&.any?

      columns.join(", ")
    end
  end
end

class MissingProjectedAttributeError < StandardError
  attr_reader :model_class, :attribute_name, :query_location, :loaded_columns

  def initialize(model_class:, attribute_name:, query_location:, loaded_columns:)
    @model_class = model_class
    @attribute_name = attribute_name
    @query_location = query_location
    @loaded_columns = Array(loaded_columns).map(&:to_s)

    super(build_message)
  end

  private

  def build_message
    location = if query_location
      "#{query_location.path}:#{query_location.lineno}"
    else
      "unknown location"
    end

    loaded = loaded_columns.empty? ? "(none)" : loaded_columns.join(", ")

    "#{model_class}##{attribute_name} was not loaded by the projected query at #{location}. Loaded columns: #{loaded}"
  end
end
