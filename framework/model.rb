require "pg"

class Model
  def self.subclasses
    @subclasses ||= []
  end

  def self.inherited(subclass)
    subclasses << subclass
    subclass.extend ClassMethods
  end

  def self.connection
    @connection ||= begin
      PG.connect(dbname: "sql_compiler_development")
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
    def table_name
      name.downcase.pluralize
    end

    def all
      connection.exec("SELECT * FROM #{table_name}").to_a
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
