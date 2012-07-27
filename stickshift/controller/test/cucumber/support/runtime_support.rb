# A small support API for runtime-centric test cases. It provides
# abstractions for an Account, Application, Gear, and Cartridge.
# The gear implementation is backed by ApplicationContainer from
# the stickshift-node package.
#
# Parts of this might be flimsy and not quite aligned with certain
# realities (especially with regards to scaling), but it should
# provide a decent starting point for the runtime tests and give
# us a single place to refactor.

require 'stickshift-node'
require 'stickshift-node/utils/shell_exec'
require 'etc'

# Some constants which might be misplaced here. Perhaps they should
# go in 00_setup_helper.rb?
$home_root ||= "/var/lib/stickshift"
$libra_httpd_conf_d ||= "/etc/httpd/conf.d/stickshift"
$cartridge_root ||= "/usr/libexec/stickshift/cartridges"
$embedded_cartridge_root ||= "/usr/libexec/stickshift/cartridges/embedded"

module StickShift
  # Represents a user account. A name and domain will be automatically
  # generated upon init,
  class TestAccount
    attr_reader :name, :domain, :apps

    def initialize(domain=nil)
      @name, @domain = gen_unique_login_and_domain(domain)
      @apps = Array.new

      # shouldn't do stuff in the constructor, but we'll live
      $logger.info("Created new account #{@name} with domain #{@domain}")
    end

    # Lifted from another test script.
    def gen_unique_login_and_domain(domain=nil)
      if !domain
        chars = ("1".."9").to_a
        domain = "ci" + Array.new(8, '').collect{chars[rand(chars.size)]}.join
      end
      login = "cucumber-test_#{domain}@example.com"
      [ login, domain ]
    end

    # Creates a new TestApplication instance associated with this account.
    def create_app()
      app = StickShift::TestApplication.new(self)

      $logger.info("Created new application #{app.name} for account #{@name}")

      @apps << app
      app
    end

    # Convenience function to get the first application for this account.
    def default_app()
      @apps[0]
    end
  end

  # Represents an application associated with an account. The name and 
  # UUID for the application is automatically generated upon init.
  class TestApplication
    attr_reader :name, :uuid, :account, :gears
    attr_accessor :hot_deploy_enabled

    def initialize(account)
      @name = gen_unique_app_name
      @uuid = gen_small_uuid
      @account = account
      @gears = Array.new

      # abstracts the hot_deploy marker file as a first class
      # property of the application
      @hot_deploy_enabled = false
    end

    # Lifted from another script.
    def gen_unique_app_name
      chars = ("1".."9").to_a
      "app" + Array.new(4, '').collect{chars[rand(chars.size)]}.join
    end

    # Lifted from another script.
    def gen_small_uuid
      %x[/usr/bin/uuidgen].gsub('-', '').strip
    end

    # Creates a new empty gear associated with this application.
    def create_gear
      gear = StickShift::TestGear.new(self)
      gear.create
      @gears << gear
      gear
    end

    # Convenience function to get the first gear associated with
    # this application.
    def default_gear
      @gears[0]
    end

    # Tears down the application by calling destroy for each gear.
    def destroy
      $logger.info("Destroying application #{@name}")
      @gears.each do |gear|
        gear.destroy
      end
    end

    # Collects and returns the PIDs for every cartridge associated
    # with this application as determined by the PID file in the 
    # cartridge instance run directory. The result is a Hash:
    #
    #   PID file basename => PID
    #
    # NOTE: This doesn't currently take into account the possibility
    # of duplicate PID filenames across gears (in a scaled instance).
    def current_cart_pids
      pids = {}

      @gears.each do |gear|
        gear.carts.values.each do |cart|
          Dir.glob("#{$home_root}/#{gear.uuid}/#{cart.name}/{run,pid}/*.pid") do |pid_file|
            $logger.info("Reading pid file #{pid_file} for cart #{cart.name}")
            pid = IO.read(pid_file).chomp
            proc_name = File.basename(pid_file, ".pid")

            pids[proc_name] = pid
          end
        end
      end

      pids
    end
  end

  # Represents a gear associated with an application. The UUID for the gear
  # is automatically generated on init.
  #
  # NOTE: Instantiating the TestGear is not enough for it to be used; make
  # sure to call TestGear.create before performing cartridge operations.
  class TestGear
    attr_reader :uuid, :carts, :app, :container

    def initialize(app)
      @uuid = gen_small_uuid
      @carts = Hash.new # cart name => cart
      @app = app
    end

    # Lifted from another script.
    def gen_small_uuid()
      %x[/usr/bin/uuidgen].gsub('-', '').strip
    end

    # Creates the physical gear on a node by delegating work to the
    # ApplicationContainer class. Be sure to call this before attempting
    # cartridge operations.
    def create()
      $logger.info("Creating new gear #{@uuid} for application #{@app.name}")

      begin
        @container = StickShift::ApplicationContainer.new(@app.uuid, @uuid, nil, @app.name, @app.name, @app.account.domain, nil, nil)
        @container.create
      rescue => e
        $logger.error(e.message)
        $logger.error(e.backtrace.join("\n"))
        raise e
      end
    end

    # Destroys the gear by:
    # - Recursively invoking deconfigure on each cart within the gear
    # - Invoking ApplicationContainer.destroy
    #
    # TODO: The cart deconfigure calls might be made redundant in the
    # near future if the logic is encapsulated in the ApplicationContainer
    # class.
    def destroy()
      $logger.info("Deconfiguring all cartridges on gear #{@uuid} of application #{@app.name}")

      # This is kind of cheesy, and should be handled at a lower layer since
      # carts actually have a dependency graph. For now, it should be good
      # enough to just make sure we deconfigure embedded carts first (as
      # deconfiguring standard ones would break deconfigure for carts 
      # embedded into the same app).
      @carts.values.each do |cart|
        cart.deconfigure if cart.type == StickShift::TestCartridge::Embedded
      end

      @carts.values.each do |cart|
        cart.deconfigure if cart.type == StickShift::TestCartridge::Standard
      end

      $logger.info("Destroying gear #{@uuid} of application #{@app.name}")
      @container.destroy
    end

    # Creates a new TestCartridge and associates it with this gear.
    #
    # NOTE: The cartridge is instantiated, but no hooks (such as 
    # configure) are executed. 
    def add_cartridge(cart_name, type = TestCartridge::Standard)
      cart = StickShift::TestCartridge.new(cart_name, self, type)
      @carts[cart.name] = cart
      cart
    end

    # Convenience function to retrieve the first cartridge for the gear.
    def default_cart()
      @carts.values[0]
    end
  end

  # Represents a cartridge associated with a gear. Supports firing events
  # and listener registration for cartridge-specific concerns.
  class TestCartridge
    include CommandHelper

    attr_reader :name, :gear, :path, :type, :metadata

    # We need to differentiate between non/embedded carts, as they have
    # different root paths on the node filesystem.
    Standard = 0
    Embedded = 1

    def initialize(name, gear, type = Standard)
      @name = name
      @gear = gear
      @type = type

      @metadata = {} # a place for cart specific helpers to put stuff

      local_root = (@type == Standard) ? $cartridge_root : $embedded_cartridge_root

      @cart_path = "#{local_root}/#{@name}"
      @hooks_path = "#{@cart_path}/info/hooks"

      # Add new listener classes here for now
      @listeners = [ StickShift::TestCartridgeListeners::DatabaseCartListener.new ]
    end

    # Convenience wrapper to invoke the configure hook.
    def configure()
      run_hook "configure"
    end

    # Convenience wrapper to invoke the deconfigure hook.
    def deconfigure()
      run_hook "deconfigure"
    end

    # Convenience wrapper to invoke the start hook.
    def start()
      run_hook "start"
    end

    # Convenience wrapper to invoke the stop hook.
    def stop()
      run_hook "stop"
    end

    # Convenience wrapper to invoke the status hook.
    def status()
      run_hook "status"
    end

    # Invokes an arbitrary hook on the cartridge, passing through
    # any extra arguments specified by extra_args (if present). An
    # exception will be raised if the exit code of the hook does 
    # not match expected_exitcode (which is 0 by default). The
    # hook is executed in the selinux context of the user and role
    # defined in the global constants provided in 00_setup_helper.
    def run_hook(hook, expected_exitcode=0, extra_args=[])
      exitcode, output = run_hook_output(hook, expected_exitcode, extra_args)
      exitcode
    end

    def run_hook_output(hook, expected_exitcode=0, extra_args=[])
      $logger.info("Running #{hook} hook for cartridge #{@name} in gear #{@gear.uuid} for application #{@gear.app.name}")
      
      cmd = %Q{#{@hooks_path}/#{hook} '#{@gear.app.name}' '#{@gear.app.account.domain}' #{@gear.uuid} #{extra_args.join(" ")}}

      output = Array.new
      exitcode = runcon cmd, $selinux_user, $selinux_role, $selinux_type, output, 45
      raise %Q{Error (#{exitcode}) running #{cmd}: #{output.join("\n")}} unless exitcode == expected_exitcode

      notify_listeners "#{hook}_hook_completed", { :cart => self, :exitcode => exitcode, :output => output}

      [exitcode, output]
    end

    # Notify cart listeners of an event
    def notify_listeners(event, args={})
      @listeners.each do |listener|
        if listener.respond_to?(event) && listener.supports?(@name)
          $logger.info("Notifying #{listener.class.name} of #{event} event")
          listener.send(event, args)
        end
      end
    end
  end

  # Cartridge listeners are intended to be invoked by TestCartridge instances
  # at various points in their lifecycle, such as post-hook. The listeners
  # are given an opportunity to respond to the results of cartridge actions
  # and attach supplementary information to the cartridge instance which
  # can be used to provide steps with cartridge specific context.
  #
  # Currently supported event patterns a listener may receive:
  #   
  #   {hook_name}_hook_completed(cart, exitcode, output)
  #     - invoked after a successful hook execution in the cartridge
  module TestCartridgeListeners
    class DatabaseCartListener
      def supports?(cart_name) 
        ['mysql-5.1', 'mongodb-2.0', 'postgresql-8.4'].include?(cart_name)
      end

      class DbConnection
        attr_accessor :username, :password, :ip, :port
      end

      # Processes the output of the cartridge configure script and scrapes 
      # it for connectivity details (such as IP and credentials).
      #
      # Adds a new attribute 'db' of type DbConnection to the cart with the
      # scraped details.
      def configure_hook_completed(args)
        $logger.info("DatabaseCartListener is processing configure hook results")

        cart = args[:cart]
        output = args[:output]

        my_username_pattern = /Root User: (\S+)/
        my_password_pattern = /Root Password: (\S+)/

        # make this smarter if there are more use cases
        ip_pattern_prefix = cart.name[/[^-]*/]
        my_ip_pattern = /#{ip_pattern_prefix}:\/\/(\d+\.\d+\.\d+\.\d+):(\d+)/

        db = DbConnection.new

        output.each do |line|
          if line.match(my_username_pattern)
            db.username = $1
          end
          if line.match(my_password_pattern)
            db.password = $1
          end
          if line.match(my_ip_pattern)
            db.ip = $1
            db.port = $2
          end
        end

        $logger.info("DatabaseCartListener is adding a DbConnection to cartridge #{cart.name}: #{db.inspect}")
        cart.instance_variable_set(:@db, db)
        cart.instance_eval('def db; @db; end')
      end
    end
  end
end