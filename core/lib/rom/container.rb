require 'rom/cache'
require 'rom/relation/loaded'
require 'rom/commands/graph'
require 'rom/commands/graph/builder'

module ROM
  # ROM container is an isolated environment with no global state where all
  # components are registered. Container objects provide access to your
  # relations, commands and mappers. ROM containers are usually configured and
  # handled via framework integrations, although it is easy to use them
  # standalone.
  #
  # There are 3 types of container setup:
  #
  # * Setup DSL - a simple block-based configuration which allows configuring
  #   all components and gives you back a container instance. This type is suitable
  #   for small scripts, or in some cases rake tasks
  # * Explicit setup - this type requires creating a configuration object,
  #   registering component classes (ie relation classes) and passing the config
  #   to container builder function. This type is suitable when your environment
  #   is not typical and you need full control over component registration
  # * Explicit setup with auto-registration - same as explicit setup but allows
  #   you to configure auto-registration mechanism which will register component
  #   classes for you, based on dir/file naming conventions. This is the most
  #   common type of setup that's used by framework integrations
  #
  # @example in-line setup
  #   rom = ROM.container(:sql, 'sqlite::memory') do |config|
  #     config.default.create_table :users do
  #       primary_key :id
  #       column :name, String, null: false
  #     end
  #
  #     config.relation(:users) do
  #       schema(infer: true)
  #
  #       def by_name(name)
  #         where(name: name)
  #       end
  #     end
  #   end
  #
  #   rom.relations[:users].insert(name: "Jane")
  #
  #   rom.relations[:users].by_name("Jane").to_a
  #   # [{:id=>1, :name=>"Jane"}]
  #
  # @example multi-step setup with explicit component classes
  #   config = ROM::Configuration.new(:sql, 'sqlite::memory')
  #
  #   config.default.create_table :users do
  #     primary_key :id
  #     column :name, String, null: false
  #   end
  #
  #   class Users < ROM::Relation[:sql]
  #     schema(:users, infer: true)
  #
  #     def by_name(name)
  #       where(name: name)
  #     end
  #   end
  #
  #   config.register_relation(Users)
  #
  #   rom = ROM.container(config)
  #
  #   rom.relations[:users].insert(name: "Jane")
  #
  #   rom.relations[:users].by_name("Jane").to_a
  #   # [{:id=>1, :name=>"Jane"}]
  #
  #
  # @example multi-step setup with auto-registration
  #   config = ROM::Configuration.new(:sql, 'sqlite::memory')
  #   config.auto_registration('./persistence', namespace: false)
  #
  #   config.default.create_table :users do
  #     primary_key :id
  #     column :name, String, null: false
  #   end
  #
  #   # ./persistence/relations/users.rb
  #   class Users < ROM::Relation[:sql]
  #     schema(infer: true)
  #
  #     def by_name(name)
  #       where(name: name)
  #     end
  #   end
  #
  #   rom = ROM.container(config)
  #
  #   rom.relations[:users].insert(name: "Jane")
  #
  #   rom.relations[:users].by_name("Jane").to_a
  #   # [{:id=>1, :name=>"Jane"}]
  #
  # @api public
  class Container
    include Dry::Equalizer(:gateways, :relations, :mappers, :commands)

    # @!attribute [r] gateways
    #   @return [Hash] A hash with configured gateways
    attr_reader :gateways

    # @!attribute [r] relations
    #   @return [RelationRegistry] The relation registry
    attr_reader :relations

    # @!attribute [r] gateways
    #   @return [CommandRegistry] The command registry
    attr_reader :commands

    # @!attribute [r] mappers
    #   @return [MapperRegistry] A hash with configured custom mappers
    attr_reader :mappers

    # @!attribute [r] mapper_compiler
    #   @return [Hash] A mapper compiler
    attr_reader :mapper_compiler

    # @!attribute [r] caches
    #   @return [Hash] A hash with configured caches for rom components
    attr_reader :caches

    # @api private
    def initialize(gateways, relations, mappers, commands)
      @caches = { mappers: Cache.new, commands: Cache.new }.freeze
      @gateways = gateways
      @mapper_compiler = MapperCompiler.new(cache: caches[:mappers])
      @mappers = mappers.map { |r| r.with(compiler: mapper_compiler, cache: caches[:mappers]) }
      @commands = commands.map { |r| r.with(cache: caches[:commands]) }
      @relations = relations.map { |r| r.with(commands: commands[r.name.to_sym]) }
    end

    # Get relation instance identified by its name
    #
    # This method will use a custom mapper if it was configured. ie if you have
    # a relation called `:users` and a mapper configured for `:users` relation,
    # then by default this mapper will be used.
    #
    # @example
    #   rom.relation(:users)
    #   rom.relation(:users).by_name('Jane')
    #
    #   # block syntax allows accessing lower-level query DSLs (usage is discouraged though)
    #   rom.relation { |r| r.restrict(name: 'Jane') }
    #
    #   # with mapping
    #   rom.relation(:users).map_with(:presenter)
    #
    #   # using multiple mappers
    #   rom.relation(:users).page(1).map_with(:presenter, :json_serializer)
    #
    # @param [Symbol] name of the relation to load
    #
    # @yield [Relation]
    #
    # @return [Relation]
    #
    # @api public
    def relation(name, &block)
      relation =
        if block
          yield(relations[name])
        else
          relations[name]
        end

      if mappers.key?(name)
        relation.with(mappers: mappers[name])
      else
        relation
      end
    end

    # Returns commands registry for the given relation
    #
    # @example
    #   # plain command without mapping
    #   rom.command(:users).create
    #
    #   # allows auto-mapping using registered mappers
    #   rom.command(:users).as(:entity)
    #
    #   # allows building up a command graph for nested input
    #   command = rom.command([:users, [:create, [:tasks, [:create]]]])
    #
    #   command.call(users: [{ name: 'Jane', tasks: [{ title: 'One' }] }])
    #
    # @param [Array,Symbol] options Either graph options or registered command name
    #
    # @return [Command, Command::Graph]
    #
    # @api public
    def command(options = nil)
      case options
      when Symbol
        name = options
        if mappers.key?(name)
          commands[name].with(mappers: mappers[name])
        else
          commands[name]
        end
      when Array
        graph = Commands::Graph.build(commands, options)
        name = graph.name

        if mappers.key?(name)
          graph.with(mappers: mappers[name])
        else
          graph
        end
      when nil
        Commands::Graph::Builder.new(self)
      else
        raise ArgumentError, "#{self.class}#command accepts a symbol or an array"
      end
    end

    # Disconnect all gateways
    #
    # @example
    #   rom = ROM.container(:sql, 'sqlite://my_db.sqlite')
    #   rom.relations[:users].insert(name: "Jane")
    #   rom.disconnect
    #
    # @return [Hash<Symbol=>Gateway>] a hash with disconnected gateways
    #
    # @api public
    def disconnect
      gateways.each_value(&:disconnect)
    end
  end
end
