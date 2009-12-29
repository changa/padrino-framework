module Padrino
  
  class Padrino::AccessControlError < StandardError; end
  
  # This module give to a padrino application an access control functionality like:
  #   
  #   class EcommerceDemo < Padrino::Application
  #     enable :authentication
  #     set :redirect_back_or_default, "/login" # or your page
  #     
  #     access_control.roles_for :any do
  #       role.require_login "/cart"
  #       role.require_login "/account"
  #       role.allow "/account/create"
  #     end
  #   end
  # 
  # In the EcommerceDemo, we <tt>only</tt> require logins for all paths that start with "/cart" like:
  # 
  #   - "/cart/add"
  #   - "/cart/empty"
  #   - "/cart/checkout"
  # 
  # same thing for "/account" so we require a login for:
  # 
  #   - "/account"
  #   - "/account/edit"
  #   - "/account/update"
  # 
  # but if we call "/account/create" we don't need to be logged in our site for do that.
  # In EcommerceDemo example we set <tt>redirect_back_or_default</tt> so if a <tt>unlogged</tt> 
  # user try to access "/account/edit" will be redirected to "/login" when login is done will be 
  # redirected to "/account/edit".
  # 
  # If we need something more complex aka roles/permissions we can do that in the same simple way
  # 
  #   class AdminDemo < Padrino::Application
  #     enable :authentication
  #     set :redirect_to_default, "/" # or your page
  #     
  #     access_control.roles_for :any do |role|
  #       role.allow "/sessions"
  #     end
  #   
  #     access_control.roles_for :admin do |role, account|
  #       role.allow "/"
  #       role.deny  "/posts"
  #     end
  #     
  #     access_control.roles_for :editor do |role, account|
  #       role.allow "/posts"
  #     end
  #   end
  # 
  #   If a user logged with role admin can:
  #   
  #   - Access to all paths that start with "/session" like "/sessions/{new,create}"
  #   - Access to any page except those that start with "/posts"
  # 
  #   If a user logged with role editor can:
  # 
  #   - Access to all paths that start with "/session" like "/sessions/{new,create}"
  #   - Access <tt>only</tt> to paths that start with "/posts" like "/post/{new,edit,destroy}"
  # 
  # Finally we have another good fatures, the possibility in the same time we build role build also <tt>tree</tt>.
  # Figure this scenario: in my admin every account need their own menu, so an Account with role editor have
  # a menu different than an Account with role admin.
  # 
  # So:
  # 
  #   class AdminDemo < Padrino::Application
  #     enable :authentication
  #     set :redirect_to_default, "/" # or your page
  #     
  #     access_control.roles_for :any do |role|
  #       role.allow "/sessions"
  #     end
  #     
  #     access_control.roles_for :admin do |role, current_account|
  #       
  #       role.project_module :settings do |project|
  #         project.menu :accounts, "/accounts" do |accounts|
  #           accounts.add :new, "/accounts/new" do |account|
  #             account.add :administrator, "/account/new/?role=administrator"               
  #             account.add :editor,        "/account/new/?role=editor"
  #           end
  #         end
  #         project.menu :spam_rules, "/manage_spam"
  #       end
  #       
  #       role.project_module :categories do |project|
  #         current_account.categories.each do |category|
  #           project.menu category.name, "/categories/#{category.id}.js"
  #         end
  #       end
  #     end
  #     
  #     access_control.roles_for :editor do |role, current_account|
  #       
  #       role.project_module :posts do |posts|
  #         post.menu :list, "/posts"
  #         post.menu :new,  "/posts/new"
  #       end
  #     end
  # 
  # In this example when we build our menu tree we are also defining roles so:
  # 
  # An Admin Account have access to:
  # 
  # - All paths that start with "/sessions"
  # - All paths that start with "/accounts"
  # - All paths that start with "/manage_spam"
  # 
  # An Editor Account have access to:
  # 
  # - All paths that start with "/posts"
  # 
  # Remember that you always deny a specific actions or allow globally others.
  # 
  # Remember that when you define role_for :a_role, you have also access to the Model Account.
  #
  module AccessControl

    def self.registered(app)
      app.helpers Padrino::AccessControl::Helpers
      app.before { login_required }
    end

    class Base

      class << self
        
        def inherited(base) #:nodoc:
          base.send(:cattr_accessor, :cache)
          base.send(:cache=, {})
          super
        end
        
        # We map project modules for a given role or roles
        def roles_for(*roles, &block)
          raise Padrino::AccessControlError, "Role #{role} must be present and must be a symbol!" if roles.any? { |r| !r.kind_of?(Symbol) } || roles.empty?
          raise Padrino::AccessControlError, "You can't merge :any with other roles"              if roles.size > 1 && roles.any? { |r| r == :any }
          @mappers        ||= []
          @roles          ||= []
          @authorizations ||= []

          if roles == [:any]
            @authorizations << Authorization.new(&block)
          else
            @roles.concat(roles)
            @mappers << Proc.new { |account| Mapper.new(account, *roles, &block) }
          end
        end

        # Returns all roles
        def roles
          @roles.nil? ? [] : @roles
        end

        # Returns maps (allowed && denied paths) for the given account.
        # An account can have access to two or many applications so for build a correct tree of maps it's 
        # also necessary provide <tt>where</tt> options.
        def maps_for(account)
          raise Padrino::AccessControlError, "You must provide an Account Class!" unless account.is_a?(Account)
          raise Padrino::AccessControlError, "Account must respond to :role!"     unless account.respond_to?(:role)
          cache[account.id] ||= Maps.new(@mappers, account)
        end
        
        # Return auths (allowed && denied pahts) for unlogged accounts.
        def auths(account=nil)
          unless cache[:any]
            maps = maps_for(account) if account
            cache[:any] = Auths.new(@authorizations, maps)
          end
          cache[:any]
        end
      end
    end

    class Maps
      attr_reader :allowed, :denied, :role, :project_modules

      def initialize(mappers, account) #:nodoc:
        @role            = role
        maps             = mappers.collect { |m|  m.call(account) }.reject { |m| !m.allowed? }
        @allowed         = maps.collect(&:allowed).flatten.uniq
        @denied          = maps.collect(&:denied).flatten.uniq
        @project_modules = maps.collect(&:project_modules).flatten.uniq
      end
    end

    class Auths
      attr_reader :allowed, :denied

      def initialize(authorizations, maps=nil)
        @allowed = authorizations.collect(&:allowed).flatten
        @denied  = authorizations.collect(&:denied).flatten
        if maps
          @allowed.concat(maps.allowed)
          @denied.concat(maps.denied)
        end
        @allowed.uniq
        @denied.uniq
      end
    end

    class Authorization
      attr_reader :allowed, :denied

      def initialize(&block)
        @allowed = []
        @denied  = []
        yield self
      end

      def allow(path)
        @allowed << path unless @allowed.include?(path)
      end

      def require_login(path)
        @denied << path unless @denied.include?(path)
      end
      alias :deny :require_login
    end

    class Mapper
      attr_reader :project_modules, :roles, :denied

      def initialize(account, *roles, &block) #:nodoc:
        @project_modules = []
        @allowed         = []
        @denied          = []
        @roles           = roles
        @account         = account.dup
        yield(self, @account)
      end

      # Create a new project module
      def project_module(name, path=nil, &block)
        @project_modules << ProjectModule.new(name, path, &block)
      end

      # Globally allow an paths for the current role
      def allow(path)
        @allowed << path unless @allowed.include?(path)
      end

      # Globally deny an pathsfor the current role
      def deny(path)
        @denied << path unless @allowed.include?(path)
      end

      # Return true if role is included in given roles
      def allowed?
        @roles.any? { |r| r == @account.role.to_s.downcase.to_sym }
      end

      # Return allowed paths
      def allowed
        @project_modules.each { |pm| @allowed.concat(pm.allowed)  }
        @allowed.uniq
      end
    end

    class ProjectModule
      attr_reader :name, :menus, :path

      def initialize(name, path=nil, options={}, &block)#:nodoc:
        @name     = name
        @options  = options
        @allowed  = []
        @menus    = []
        @path     = path
        @allowed << path if path
        yield self
      end

      # Build a new menu and automaitcally add the action on the allowed actions.
      def menu(name, path=nil, options={}, &block)
        @menus << Menu.new(name, path, options, &block)
      end

      # Return allowed controllers
      def allowed
        @menus.each { |m| @allowed.concat(m.allowed) }
        @allowed.uniq
      end

      # Return the original name or try to translate or humanize the symbol
      def human_name
        @name.is_a?(Symbol) ? I18n.t("admin.menus.#{@name}", :default => @name.to_s.humanize) : @name
      end

      # Return symbol for the given project module
      def uid
        @name.to_s.downcase.gsub(/[^a-z0-9]+/, '').gsub(/-+$/, '').gsub(/^-+$/, '').to_sym
      end

      # Return ExtJs Config for this project module
      def config
        options = @options.merge(:text => human_name)
        options.merge!(:menu => @menus.collect(&:config)) if @menus.size > 0
        options.merge!(:handler => ExtJs::Variable.new("function(){ Admin.app.load('#{path}') }")) if @path
        options
      end
    end

    class Menu
      attr_reader :name, :options, :items, :path

      def initialize(name, path=nil, options={}, &block) #:nodoc:
        @name    = name
        @path    = path
        @options = options
        @allowed = []
        @items   = []        
        @allowed << path if path
        yield self if block_given?
      end

      # Add a new submenu to the menu
      def add(name, path=nil, options={}, &block)
        @items << Menu.new(name, path, options, &block)
      end

      # Return allowed controllers
      def allowed
        @items.each { |i| @allowed.concat(i.allowed) }
        @allowed.uniq
      end

      # Return the original name or try to translate or humanize the symbol
      def human_name
        @name.is_a?(Symbol) ? I18n.t("admin.menus.#{@name}", :default => @name.to_s.humanize) : @name
      end

      # Return a unique id for the given project module
      def uid
        @name.to_s.downcase.gsub(/[^a-z0-9]+/, '').gsub(/-+$/, '').gsub(/^-+$/, '').to_sym
      end

      # Return ExtJs Config for this menu
      def config
        if @path.blank? && @items.empty?
          options = human_name
        else
          options = @options.merge(:text => human_name)
          options.merge!(:menu => @items.collect(&:config)) if @items.size > 0
          options.merge!(:handler => ExtJs::Variable.new("function(){ Admin.app.load('#{path}') }")) if @path
        end
        options
      end
    end
  end
end