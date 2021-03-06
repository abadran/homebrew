# Comprehensively test a formula or pull request.
#
# Usage: brew test-bot [options...] <pull-request|formula>
#
# Options:
# --keep-logs:    Write and keep log files under ./brewbot/
# --cleanup:      Clean the Homebrew directory. Very dangerous. Use with care.
# --skip-setup:   Don't check the local system is setup correctly.
# --junit:        Generate a JUnit XML test results file.

require 'formula'
require 'utils'
require 'date'
require 'erb'

HOMEBREW_CONTRIBUTED_CMDS = HOMEBREW_REPOSITORY + "Library/Contributions/cmd/"

class Step
  attr_reader :command, :name, :status, :output, :time

  def initialize test, command, puts_output_on_success = false
    @test = test
    @category = test.category
    @command = command
    @puts_output_on_success = puts_output_on_success
    @name = command.split[1].delete '-'
    @status = :running
    @repository = HOMEBREW_REPOSITORY
    @time = 0
  end

  def log_file_path full_path=true
    file = "#{@category}.#{@name}.txt"
    return file unless @test.log_root and full_path
    @test.log_root + file
  end

  def status_colour
    case @status
    when :passed  then "green"
    when :running then "orange"
    when :failed  then "red"
    end
  end

  def status_upcase
    @status.to_s.upcase
  end

  def passed?
    @status == :passed
  end

  def failed?
    @status == :failed
  end

  def puts_command
    print "#{Tty.blue}==>#{Tty.white} #{@command}#{Tty.reset}"
    tabs = (80 - "PASSED".length + 1 - @command.length) / 8
    tabs.times{ print "\t" }
    $stdout.flush
  end

  def puts_result
    puts "#{Tty.send status_colour}#{status_upcase}#{Tty.reset}"
  end

  def has_output?
    @output and @output.any?
  end

  def run
    puts_command

    start_time = Time.now
    run_command = "#{@command} &>#{log_file_path}"
    if run_command.start_with? 'git '
      Dir.chdir @repository do
        `#{run_command}`
      end
    else
      `#{run_command}`
    end
    end_time = Time.now
    @time = end_time - start_time

    success = $?.success?
    @status = success ? :passed : :failed
    puts_result

    return unless File.exists?(log_file_path)
    @output = IO.read(log_file_path)
    if has_output? and (not success or @puts_output_on_success)
      puts @output
    end
    FileUtils.rm log_file_path unless ARGV.include? "--keep-logs"
  end
end

class Test
  attr_reader :log_root, :category, :name, :core_changed, :formulae, :steps

  def initialize argument
    @hash = nil
    @url = nil
    @formulae = []

    url_match = argument.match HOMEBREW_PULL_URL_REGEX
    formula = Formula.factory argument rescue FormulaUnavailableError
    git "rev-parse --verify #{argument} &>/dev/null"
    if $?.success?
      @hash = argument
    elsif url_match
      @url = url_match[0]
    elsif formula
      @formulae = [argument]
    else
      odie "#{argument} is not a pull request URL, commit URL or formula name."
    end

    @category = __method__
    @steps = []
    @core_changed = false
    @brewbot_root = Pathname.pwd + "brewbot"
    FileUtils.mkdir_p @brewbot_root
  end

  def git arguments
    Dir.chdir HOMEBREW_REPOSITORY do
      `git #{arguments}`
    end
  end

  def download
    def shorten_revision revision
      git("rev-parse --short #{revision}").strip
    end

    def current_sha1
      shorten_revision 'HEAD'
    end

    def current_branch
      git('symbolic-ref HEAD').gsub('refs/heads/', '').strip
    end

    @category = __method__
    @start_branch = current_branch

    # Use Jenkins environment variables if present.
    if ENV['GIT_PREVIOUS_COMMIT'] and ENV['GIT_COMMIT']
      diff_start_sha1 = shorten_revision ENV['GIT_PREVIOUS_COMMIT']
      diff_end_sha1 = shorten_revision ENV['GIT_COMMIT']
      test "brew update" if current_branch == "master"
    elsif @hash or @url
      diff_start_sha1 = current_sha1
      test "brew update" if current_branch == "master"
      diff_end_sha1 = current_sha1
    end

    if @hash == 'HEAD'
      if diff_start_sha1 == diff_end_sha1
        @name = diff_end_sha1
      else
        @name = "#{diff_start_sha1}-#{diff_end_sha1}"
      end
    elsif @hash
      test "git checkout #{@hash}"
      diff_start_sha1 = "#{@hash}^"
      diff_end_sha1 = @hash
      @name = @hash
    elsif @url
      test "git checkout #{current_sha1}"
      test "brew pull --clean #{@url}"
      diff_end_sha1 = current_sha1
      @name = "#{@url}-#{diff_end_sha1}"
    else
      diff_start_sha1 = diff_end_sha1 = current_sha1
      @name = "#{@formulae.first}-#{diff_end_sha1}"
    end

    @log_root = @brewbot_root + @name
    FileUtils.mkdir_p @log_root

    return unless diff_start_sha1 != diff_end_sha1
    return if @url and not steps.last.passed?

    diff_stat = git "diff #{diff_start_sha1}..#{diff_end_sha1} --name-status"
    diff_stat.each_line do |line|
      status, filename = line.split
      # Don't try and do anything to removed files.
      if (status == 'A' or status == 'M')
        if filename.include? '/Formula/'
          @formulae << File.basename(filename, '.rb')
        end
      end
      if filename.include? '/Homebrew/' or filename.include? '/ENV/' \
        or filename.include? 'bin/brew'
        @core_changed = true
      end
    end
  end

  def setup
    @category = __method__

    test "brew doctor"
    test "brew --env"
    test "brew --config"
  end

  def formula formula
    @category = __method__.to_s + ".#{formula}"

    dependencies = `brew deps #{formula}`.split("\n")
    dependencies -= `brew list`.split("\n")
    dependencies = dependencies.join(' ')
    formula_object = Formula.factory(formula)

    test "brew audit #{formula}"
    test "brew fetch #{dependencies}" unless dependencies.empty?
    test "brew fetch --build-bottle #{formula}"
    test "brew install --verbose #{dependencies}" unless dependencies.empty?
    test "brew install --verbose --build-bottle #{formula}"
    return unless steps.last.passed?
    test "brew bottle #{formula}", true
    bottle_revision = bottle_new_revision(formula_object)
    bottle_filename = bottle_filename(formula_object, bottle_revision)
    test "brew uninstall #{formula}"
    test "brew install #{bottle_filename}"
    test "brew test #{formula}" if formula_object.test_defined?
    test "brew uninstall #{formula}"
    test "brew uninstall #{dependencies}" unless dependencies.empty?
  end

  def homebrew
    @category = __method__
    test "brew tests"
    test "brew readall"
  end

  def cleanup_before
    @category = __method__
    return unless ARGV.include? '--cleanup'
    git 'stash'
    git 'am --abort 2>/dev/null'
    git 'rebase --abort 2>/dev/null'
    git 'checkout -f master'
    git 'reset --hard'
    git 'clean --force -dx'
  end

  def cleanup_after
    @category = __method__
    force_flag = ''
    if ARGV.include? '--cleanup'
      test 'brew cleanup'
      test 'git clean --force -dx'
      force_flag = '-f'
    end

    if ARGV.include? '--cleanup' or @url or @hash
      test "git checkout #{force_flag} #{@start_branch}"
    end

    if ARGV.include? '--cleanup'
      test 'git reset --hard'
      test 'git gc'
      git 'stash pop 2>/dev/null'
    end

    FileUtils.rm_rf @brewbot_root unless ARGV.include? "--keep-logs"
  end

  def test cmd, puts_output_on_success = false
    step = Step.new self, cmd, puts_output_on_success
    step.run
    steps << step
  end

  def check_results
    message = "All tests passed and raring to brew."

    status = :passed
    steps.each do |step|
      case step.status
      when :passed  then next
      when :running then raise
      when :failed  then
        if status == :passed
          status = :failed
          message = ""
        end
        message += "#{step.command}: #{step.status.to_s.upcase}\n"
      end
    end
    status == :passed
  end

  def run
    cleanup_before
    download
    setup unless ARGV.include? "--skip-setup"
    formulae.each do |f|
      formula(f)
    end
    homebrew if core_changed
    cleanup_after
    check_results
  end
end

if Pathname.pwd == HOMEBREW_PREFIX and ARGV.include? "--cleanup"
  odie 'cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output.'
end

tests = []
any_errors = false
if ARGV.named.empty?
  # With no arguments just build the most recent commit.
  test = Test.new('HEAD')
  any_errors = test.run
  tests << test
else
  ARGV.named.each do |argument|
    test = Test.new(argument)
    any_errors = test.run or any_errors
    tests << test
  end
end

if ARGV.include? "--junit"
  xml_erb = HOMEBREW_CONTRIBUTED_CMDS + "brew-test-bot.xml.erb"
  erb = ERB.new IO.read xml_erb
  open("brew-test-bot.xml", "w") do |xml|
    # Remove empty lines and null characters from ERB result.
    xml.write erb.result(binding).gsub(/^\s*$\n|\000/, '')
  end
end

exit any_errors ? 0 : 1
