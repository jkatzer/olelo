module Olelo
  # Olelo plugin system
  class Plugin < Module
    include Util
    include Hooks

    has_around_hooks :load

    @loaded = {}
    @failed = []
    @disabled = []
    @dir = ''

    class<< self
      attr_accessor :dir, :disabled

      # Get failed plugins
      attr_reader :failed

      # Get loaded plugins
      def loaded
        @loaded.values
      end

      # Start plugins
      # @return [void]
      def start
        @loaded.each_value {|plugin| plugin.start }
      end

      def register(path, plugin)
        @loaded[path] = plugin
      end

      # Load plugin by path
      #
      # @param [String] path Plugin path to load
      # @return [Boolean] true if every plugin was loaded
      def load(path)
        path = path.sub(%r{/main$}, '')
        files = [File.join(@dir, path, 'main.rb'), File.join(@dir, "#{path}.rb")].select {|file| File.file?(file) }
        if files.size == 2
          Olelo.logger.error "Duplicate plugin #{files.join(', ')}"
          return false
        end
        return false if files.empty?

        if @loaded.include?(path)
          true
        elsif @failed.include?(path) || !enabled?(path)
          false
        else
          begin
            new(path, files.first)
            true
          rescue Exception => ex
            @failed << path
            if LoadError === ex
              Olelo.logger.warn "Plugin #{path} could not be loaded due to: #{ex.message} (Missing gem?)"
            else
              Olelo.logger.error "Plugin #{path} could not be loaded due to: #{ex.message}"
              Olelo.logger.debug ex
            end
            @loaded.delete(path)
            false
	  end
        end
      end

      # Load all plugins
      def load_all
        Dir[File.join(@dir, '**', '*.rb')].inject(true) {|result,file| load(file[(@dir.size+1)..-4]) && result }
      end

      # Check if plugin is enabled
      #
      # @param [String] plugin path
      # @return [Boolean] true if enabled
      #
      def enabled?(path)
        path.split('/').inject('') do |parent, x|
          parent /= x
          return false if disabled.include?(parent)
          parent
        end
        true
      end

      def for(obj)
        if Module === obj
          names = obj.name.split('::')
          mod = Object
          names.map {|name| mod = mod.const_get(name) }.reverse.each do |m|
            return m if Plugin === m
          end
        elsif Proc === obj
          return obj.binding.eval('PLUGIN')
        else
          raise 'Plugin cannot be found for #{obj}'
        end
      end
    end

    attr_reader :path, :file
    attr_setter :description
    attr_reader? :started

    def initialize(path, file)
      @setup = nil
      @path, @file = path, file
      @started = false
      @dependencies = Set.new
      const_set(:PLUGIN, self)

      with_hooks :load do
        names = path.split('/')
        names[0..-2].inject('') do |parent, x|
          parent /= x
          Plugin.load(parent)
          parent
        end

        (0...names.length).inject(Plugin) do |mod, i|
          elem = names[i].split('_').map(&:capitalize).join
          if mod.const_defined?(elem, false)
            mod.const_get(elem)
          else
            child = i == names.length - 1 ? self : Module.new
            child.module_eval { include mod } if mod != Plugin # Include parent module
            mod.const_set(elem, child)
          end
        end

        Plugin.register(path, self)
        module_eval(File.read(file), file)
        Olelo.logger.debug("Plugin #{path} successfully loaded")
      end
    end

    # Virtual filesystem used to load plugin assets
    def virtual_fs
      VirtualFS::Union.new(VirtualFS::Embedded.new(file),
                           VirtualFS::Native.new(File.dirname(file)))
    end

    # Start the plugin by calling the {#setup} method
    #
    # @return [Boolean] true for success
    def start
      return true if @started
      module_eval(&@setup) if @setup
      Olelo.logger.debug "Plugin #{path} successfully started"
      @started = true
    rescue Exception => ex
      Olelo.logger.error "Plugin #{path} failed to start due to: #{ex.message}"
      Olelo.logger.error ex
      false
    end

    # Load specified plugins and fail with LoadError if dependencies are missing
    #
    # @param list List of plugin paths to load
    # @return List of dependencies (plugin paths)
    def dependencies(*list)
      if !list.empty?
        raise 'Plugin is already started' if started?
        @dependencies.merge(list)
        list.each do |dep|
          raise(LoadError, "Could not load dependency #{dep} for #{path}") if !Plugin.load(dep)
        end
      end
      @dependencies
    end

    def setup(&block)
      @setup = block
    end

    private_class_method :new
  end
end
