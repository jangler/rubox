require_relative 'text'

# Module containing definitions for client commands.
module Commands

  # Exception indicating that a client command was given the wrong number of
  # arguments.
  class UsageError < ArgumentError
  end

  # A client command. Contains metadata as well as execution procedure.
  class Command

    # A +String+ specifying the usage of the command in the style of a man page
    # synopsis. Optional arguments are enclosed in brackets; varargs-style
    # arguments are suffixed with an ellipsis.
    attr_reader :usage

    # A complete description of the command, suitable for display to the end
    # user.
    attr_reader :description

    # Create a new +Command+ with the given metadata and a +Proc+ specifying
    # its behavior. The +Proc+ will receive four arguments: the
    # +DropboxClient+, the +State+, an +Array+ of command-line arguments, and
    # a +Proc+ to be called for output.
    def initialize(usage, description, procedure)
      @usage = usage
      @description = description.squeeze(' ')
      @procedure = procedure
    end

    # Attempt to execute the +Command+, yielding lines of output if a block is
    # given. Raises a +UsageError+ if an invalid number of command-line
    # arguments is given.
    def exec(client, state, *args)
      if num_args_ok?(args.length)
        block = proc { |line| yield line if block_given? }
        @procedure.yield(client, state, args, block)
      else
        raise UsageError.new(@usage)
      end
    end

    # Return a +String+ describing the type of argument at the given index.
    # If the index is out of range, return the type of the final argument. If
    # the +Command+ takes no arguments, return +nil+.
    def type_of_arg(index)
      args = @usage.split.drop(1)
      if args.empty?
        nil
      else
        index = [index, args.length - 1].min
        args[index].tr('[].', '')
      end
    end

    private

    def num_args_ok?(num_args)
      args = @usage.split.drop(1)
      min_args = args.reject { |arg| arg.start_with?('[') }.length
      if args.empty?
        max_args = 0
      elsif args.last.end_with?('...')
        max_args = num_args
      else
        max_args = args.length
      end
      (min_args..max_args).include?(num_args)
    end
  end

  # Change the remote working directory.
  CD = Command.new(
    'cd [REMOTE_DIR]',
    "Change the remote working directory. With no arguments, changes to the \
     Dropbox root. With a remote directory name as the argument, changes to \
     that directory. With - as the argument, changes to the previous working \
     directory.",
    lambda do |client, state, args, output|
      if args.empty?
        state.pwd = '/'
      elsif args[0] == '-'
        state.pwd = state.oldpwd
      else
        path = state.resolve_path(args[0])
        if state.directory?(path)
          state.pwd = path
        else
          output.call('Not a directory')
        end
      end
    end
  )

  # Terminate the session.
  EXIT = Command.new(
    'exit',
    "Exit the program.",
    lambda do |client, state, args, output|
      state.exit_requested = true
    end
  )

  # Download remote files.
  GET = Command.new(
    'get REMOTE_FILE...',
    "Download each specified remote file to a file of the same name in the \
     local working directory.",
    lambda do |client, state, args, output|
      state.expand_patterns(args).each do |path|
        begin
          contents = client.get_file(path)
          File.open(File.basename(path), 'wb') do |file|
            file.write(contents)
          end
        rescue DropboxError => error
          output.call(error.to_s)
        end
      end
    end
  )

  # List commands, or print information about a specific command.
  HELP = Command.new(
    'help [COMMAND]',
    "Print usage and help information about a command. If no command is \
     given, print a list of commands instead.",
    lambda do |client, state, args, output|
      if args.empty?
        Text.table(NAMES).each { |line| output.call(line) }
      else
        cmd_name = args[0]
        if NAMES.include?(cmd_name)
          cmd = const_get(cmd_name.upcase.to_s)
          output.call(cmd.usage)
          Text.wrap(cmd.description).each { |line| output.call(line) }
        else
          output.call("Unrecognized command: #{cmd_name}")
        end
      end
    end
  )

  # Change the local working directory.
  LCD = Command.new(
    'lcd [LOCAL_DIR]',
    "Change the local working directory. With no arguments, changes to the \
     home directory. With a local directory name as the argument, changes to \
     that directory. With - as the argument, changes to the previous working \
     directory.",
    lambda do |client, state, args, output|
      path = if args.empty?
        File.expand_path('~')
      elsif args[0] == '-'
        state.local_oldpwd
      else
        File.expand_path(args[0])
      end

      if Dir.exists?(path)
        state.local_oldpwd = Dir.pwd
        Dir.chdir(path)
      else
        output.call("lcd: #{args[0]}: No such file or directory")
      end
    end
  )

  # List remote files.
  LS = Command.new(
    'ls [REMOTE_FILE]...',
    "List information about remote files. With no arguments, list the \
     contents of the working directory. When given remote directories as \
     arguments, list the contents of the directories. When given remote files \
     as arguments, list the files.",
    lambda do |client, state, args, output|
      patterns = if args.empty?
        ["#{state.pwd}/*".sub('//', '/')]
      else
        args.map do |path|
          path = state.resolve_path(path)
          begin
            if state.directory?(path)
              "#{path}/*".sub('//', '/')
            else
              path
            end
          rescue DropboxError
            path
          end
        end
      end

      items = []
      patterns.each do |pattern|
        begin
          dir = File.dirname(pattern)
          state.contents(dir).each do |path|
            items << File.basename(path) if File.fnmatch(pattern, path)
          end
        rescue DropboxError => error
          output.call(error.to_s)
        end
      end
      Text.table(items).each { |item| output.call(item) }
    end
  )

  # Create a remote directory.
  MKDIR = Command.new(
    'mkdir REMOTE_DIR...',
    "Create remote directories.",
    lambda do |client, state, args, output|
      args.each do |arg|
        begin
          path = state.resolve_path(arg)
          state.cache[path] = client.file_create_folder(path)
        rescue DropboxError => error
          output.call(error.to_s)
        end
      end
    end
  )

  # Upload a local file.
  PUT = Command.new(
    'put LOCAL_FILE [REMOTE_FILE]',
    "Upload a local file to a remote path. If a remote file of the same name \
     already exists, Dropbox will rename the upload. When given only a local \
     file path, the remote path defaults to a file of the same name in the \
     remote working directory.",
    lambda do |client, state, args, output|
      from_path = args[0]
      if args.length == 2
        to_path = args[1]
      else
        to_path = File.basename(from_path)
      end
      to_path = state.resolve_path(to_path)

      begin
        File.open(File.expand_path(from_path), 'rb') do |file|
          state.cache[to_path] = client.put_file(to_path, file)
        end
      rescue Exception => error
        output.call(error.to_s)
      end
    end
  )

  # Remove remote files.
  RM = Command.new(
    'rm REMOTE_FILE...',
    "Remove each specified remote file or directory.",
    lambda do |client, state, args, output|
      state.expand_patterns(args).each do |path|
        begin
          client.file_delete(path)
          state.cache.delete(path)
        rescue DropboxError => error
          output.call(error.to_s)
        end
      end
    end
  )

  # Get links to remote files.
  SHARE = Command.new(
    'share REMOTE_FILE...',
    "Create Dropbox links to publicly share remote files. The links are \
     shortened and direct to 'preview' pages of the files. Links created by \
     this method are set to expire far enough in the future so that \
     expiration is effectively not an issue.",
    lambda do |client, state, args, output|
      state.expand_patterns(args).each do |path|
        begin
          output.call("#{path}: #{client.shares(path)['url']}")
        rescue DropboxError => error
          output.call(error.to_s)
        end
      end
    end
  )

  # +Array+ of all command names.
  NAMES = constants.select do |sym|
     const_get(sym).is_a?(Command)
  end.map { |sym| sym.to_s.downcase }

  # Parse and execute a line of user input in the given context.
  def self.exec(input, client, state)
    if input.start_with?('!')
      shell(input[1, input.length - 1]) { |line| puts line }
    elsif not input.empty?
      tokens = input.split

      # Escape spaces with backslash
      i = 0
      while i < tokens.length - 1
        if tokens[i].end_with?('\\')
          tokens[i] = "#{tokens[i].chop} #{tokens.delete_at(i + 1)}"
        else
          i += 1
        end
      end

      cmd, args = tokens[0], tokens.drop(1)

      if NAMES.include?(cmd)
        begin
          const_get(cmd.upcase.to_sym).exec(client, state, *args) do |line|
            puts line
          end
        rescue UsageError => error
          puts "Usage: #{error}"
        end
      else
        puts "Unrecognized command: #{cmd}"
      end
    end
  end

  private

  def self.shell(cmd)
    begin
      IO.popen(cmd) do |pipe|
        pipe.each_line { |line| yield line.chomp if block_given? }
      end
    rescue Interrupt
    rescue Exception => error
      yield error.to_s if block_given?
    end
  end

end