module Graphiti
  class Scope
    attr_accessor :object, :unpaginated_object

    def initialize(object, resource, query, opts = {})
      @object    = object
      @resource  = resource
      @query     = query
      @opts      = opts

      @object = @resource.around_scoping(@object, @query.hash) do |scope|
        apply_scoping(scope, opts)
      end
    end

    def resolve
      if @query.zero_results?
        []
      else
        resolved = @resource.resolve(@object)
        assign_serializer(resolved)
        yield resolved if block_given?
        if @opts[:after_resolve]
          @opts[:after_resolve].call(resolved)
        end
        sideload(resolved) unless @query.sideloads.empty?
        resolved
      end
    end

    private

    # Used to ensure the resource's serializer is used
    # Not one derived through the usual jsonapi-rb logic
    def assign_serializer(records)
      records.each do |r|
        @resource.decorate_record(r)
      end
    end

    def sideload(results)
      return if results == []

      concurrent = Graphiti.config.concurrency
      promises = []

      @query.sideloads.each_pair do |name, q|
        sideload = @resource.class.sideload(name)
        resolve_sideload = -> {
          sideload.resolve(results, q)
          if concurrent && defined?(ActiveRecord)
            ActiveRecord::Base.clear_active_connections!
          end
        }
        if concurrent
          promises << Concurrent::Promise.execute(&resolve_sideload)
        else
          resolve_sideload.call
        end
      end

      if concurrent
        # Wait for all promises to finish
        while !promises.all? { |p| p.fulfilled? || p.rejected? }
          sleep 0.01
        end
        # Re-raise the error with correct stacktrace
        # OPTION** to avoid failing here?? if so need serializable patch
        # to avoid loading data when association not loaded
        if rejected = promises.find(&:rejected?)
          raise rejected.reason
        end
      end
    end

    def apply_scoping(scope, opts)
      @object = scope
      add_scoping(nil, Graphiti::Scoping::DefaultFilter, opts)
      add_scoping(:filter, Graphiti::Scoping::Filter, opts)
      add_scoping(:sort, Graphiti::Scoping::Sort, opts)
      add_scoping(:paginate, Graphiti::Scoping::Paginate, opts)
      @object
    end

    def add_scoping(key, scoping_class, opts, default = {})
      @object = scoping_class.new(@resource, @query.hash, @object, opts).apply
      @unpaginated_object = @object unless key == :paginate
    end
  end
end
