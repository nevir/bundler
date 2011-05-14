require "digest/sha1"

module Bundler
  class Runtime < Environment
    include SharedHelpers

    def setup(*groups)
      # Has to happen first
      clean_load_path

      specs = groups.any? ? @definition.specs_for(groups) : requested_specs

      setup_environment
      Bundler.rubygems.replace_entrypoints(specs)

      # Activate the specs
      specs.each do |spec|
        unless spec.loaded_from
          raise GemNotFound, "#{spec.full_name} is missing. Run `bundle` to get it."
        end

        if activated_spec = Bundler.rubygems.loaded_specs(spec.name) and activated_spec.version != spec.version
          e = Gem::LoadError.new "You have already activated #{activated_spec.name} #{activated_spec.version}, " \
                                 "but your Gemfile requires #{spec.name} #{spec.version}. Consider using bundle exec."
          e.name = spec.name
          if e.respond_to?(:requirement=)
            e.requirement = Gem::Requirement.new(spec.version.to_s)
          else
            e.version_requirement = Gem::Requirement.new(spec.version.to_s)
          end
          raise e
        end

        Bundler.rubygems.mark_loaded(spec)
        load_paths = spec.load_paths.reject {|path| $LOAD_PATH.include?(path)}
        $LOAD_PATH.unshift(*load_paths)
      end

      lock

      self
    end

    REGEXPS = [
      /^no such file to load -- (.+)$/i,
      /^Missing \w+ (?:file\s*)?([^\s]+.rb)$/i,
      /^Missing API definition file in (.+)$/i,
      /^cannot load such file -- (.+)$/i,
    ]

    def require(*groups)
      each_loadable_dependency(*groups) do |dep|
        require_dependency(dep)
      end
    end
    
    def autoload(*groups)
      each_loadable_dependency(*groups) do |dep|
        autoload_dependency(dep)
      end
    end

    def require_dependency(dependency)
      required_file = nil

      begin
        # Loop through all the specified autorequires for the
        # dependency. If there are none, use the dependency's name
        # as the autorequire.
        Array(dependency.autorequire || dependency.name).each do |file|
          required_file = file
          Kernel.require file
        end
      rescue LoadError => e
        REGEXPS.find { |r| r =~ e.message }
        raise if dependency.autorequire || $1 != required_file
      end
    end
    
    def autoload_dependency(dependency)
      # If we explicitly disabled autoload, but did not explicitly disable require, go ahead and
      # require the gem
      if dependency.autorequire.nil? && dependency.autoload_symbols && dependency.autoload_symbols.empty?
        return require_dependency(dependency)
      end
      
      # Either the dependency has a set of symbols defined, or we try to guess from its name
      symbols = Array(dependency.autoload_symbols || dependency.name.split(/[_\-]/).each {|w| w.capitalize!}.join)
      
      DependencyAutoloader.register_dependency(self, dependency, symbols)
    end

    def each_loadable_dependency(*groups)
      groups.map! { |g| g.to_sym }
      groups = [:default] if groups.empty?

      @definition.dependencies.each do |dep|
        # Only require the dependency if it is not in any of the 
        # requested groups
        yield(dep) if ((dep.groups & groups).any? && dep.current_platform?)
      end
    end

    def dependencies_for(*groups)
      if groups.empty?
        dependencies
      else
        dependencies.select { |d| (groups & d.groups).any? }
      end
    end

    alias gems specs

    def cache
      FileUtils.mkdir_p(cache_path)

      Bundler.ui.info "Updating .gem files in vendor/cache"
      specs.each do |spec|
        next if spec.name == 'bundler'
        spec.source.cache(spec) if spec.source.respond_to?(:cache)
      end
      prune_cache unless Bundler.settings[:no_prune]
    end

    def prune_cache
      FileUtils.mkdir_p(cache_path)

      resolve = @definition.resolve
      cached  = Dir["#{cache_path}/*.gem"]

      cached = cached.delete_if do |path|
        spec = Bundler.rubygems.spec_from_gem path

        resolve.any? do |s|
          s.name == spec.name && s.version == spec.version && !s.source.is_a?(Bundler::Source::Git)
        end
      end

      if cached.any?
        Bundler.ui.info "Removing outdated .gem files from vendor/cache"

        cached.each do |path|
          Bundler.ui.info "  * #{File.basename(path)}"
          File.delete(path)
        end
      end
    end

  private

    def cache_path
      root.join("vendor/cache")
    end

    def setup_environment
      begin
        ENV["BUNDLE_BIN_PATH"] = Bundler.rubygems.bin_path("bundler", "bundle", VERSION)
      rescue Gem::GemNotFoundException
        ENV["BUNDLE_BIN_PATH"] = File.expand_path("../../../bin/bundle", __FILE__)
      end

      # Set PATH
      paths = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
      paths.unshift "#{Bundler.bundle_path}/bin"
      ENV["PATH"] = paths.uniq.join(File::PATH_SEPARATOR)

      # Set BUNDLE_GEMFILE
      ENV["BUNDLE_GEMFILE"] = default_gemfile.to_s

      # Set RUBYOPT
      rubyopt = [ENV["RUBYOPT"]].compact
      if rubyopt.empty? || rubyopt.first !~ /-rbundler\/setup/
        rubyopt.unshift "-rbundler/setup"
        rubyopt.unshift "-I#{File.expand_path('../..', __FILE__)}"
        ENV["RUBYOPT"] = rubyopt.join(' ')
      end
    end
  end
end
