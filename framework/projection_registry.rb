class ProjectionRegistry
  UNSAFE = Object.new

  class << self
    def load!
      @projections = StaticProjectionCompiler.new.compile
    end

    def clear!
      @projections = {}
    end

    def projections
      @projections
    end

    def lookup(path:, line:, model_class:, query_kind:)
      entry = projections[key_for(path:, line:, model_class:, query_kind:)]
      return if entry.nil? || entry.equal?(UNSAFE)

      entry
    end

    def entry_for(path:, line:, model_class:, query_kind:)
      projections[key_for(path:, line:, model_class:, query_kind:)]
    end

    def key_for(path:, line:, model_class:, query_kind:)
      [File.expand_path(path), Integer(line), model_class.name, query_kind.to_sym]
    end
  end
end
