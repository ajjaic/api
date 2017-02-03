class IsolateJob < ApplicationJob
  queue_as :default

  STDIN_FILE = 'stdin.txt'
  STDOUT_FILE = 'stdout.txt'
  STDERR_FILE = 'stderr.txt'
  META_FILE = 'meta.txt'

  attr_reader :submission, :workdir, :box, :source, :stdin, :stdout, :stderr,
              :meta, :parsed_meta, :id

  def perform(submission)
    @submission = submission
    time = []
    memory = []

    submission.update(status: Status.process)
    submission.number_of_runs.times do
      init
      write
      if compile == :failure
        clean
        return
      end
      run
      verify

      time << submission.time
      memory << submission.memory

      clean
      break if submission.status != Status.ac
    end

    submission.time = time.inject(&:+).to_f / time.size
    submission.memory = memory.inject(&:+).to_f / memory.size
    submission.save

  rescue Exception => e
    submission.stderr = e.message
    submission.status = Status.boxerr
    submission.save
    clean
  end

  private

  def init
    @id = submission.id%2147483647
    @workdir = `isolate --cg -b #{id} --init`.chomp
    @box = workdir + "/box/"

    @source = box + "#{submission.language.source_file}"
    @stdin = box + STDIN_FILE
    @stdout = box + STDOUT_FILE
    @stderr = box + STDERR_FILE
    @meta = box + META_FILE
  end

  def write
    File.open(source, 'w') { |f| f.write(submission.source_code) }
    File.open(stdin, 'w') { |f| f.write(submission.input) }
  end

  def compile
    return :success unless submission.language.compile_cmd

    errors = `cd #{box} && #{submission.language.compile_cmd} 2>&1`
    return :success if $?.success?

    submission.update(
      stderr: errors,
      status: Status.ce,
      finished_at: DateTime.now
    )
    :failure
  end

  def run
    `isolate --cg \
    #{Rails.env.development? ? '-v' : ''} \
    -b #{id} \
    -i #{STDIN_FILE} \
    -o #{STDOUT_FILE} \
    -r #{STDERR_FILE} \
    -M #{meta} \
    -t #{Config::CPU_TIME_LIMIT} \
    -x #{Config::CPU_EXTRA_TIME} \
    -w #{Config::WALL_TIME_LIMIT} \
    -k #{Config::STACK_LIMIT} \
    -p#{Config::MAX_PROCESSES_AND_OR_THREADS} \
    #{Config::ENABLE_PER_PROCESS_AND_THREAD_MEMORY_LIMIT ? "-m " : "--cg-mem="}#{Config::MEMORY_LIMIT} \
    #{Config::ENABLE_PER_PROCESS_AND_THREAD_TIME_LIMIT ? "" : "--cg-timing"} \
    -f #{Config::MAX_FILE_SIZE} \
    -E HOME=#{workdir} \
    -d '/etc':'noexec' \
    --run \
    -- #{submission.language.run_cmd}`
  end

  def verify
    submission.finished_at = DateTime.now

    change_permissions
    parse_meta

    submission.time = parsed_meta["time"].to_f
    submission.memory = parsed_meta["cg-mem"].to_i
    submission.stdout = fix_encoding(File.read(stdout))
    submission.stderr = fix_encoding(File.read(stderr))

    submission.status = determine_status
    if submission.status.boxerr?
      preappend = submission.stderr.present? ? "\n" : ""
      submission.stderr += preappend + parsed_meta["message"]
    end
  end

  def clean
    `isolate --cg -b #{id} --cleanup`
  end

  def change_permissions
    `sudo chown $(whoami): #{box} #{meta} #{stdout} #{stderr}`
  end

  def fix_encoding(text)
    return text if text.valid_encoding?
    text.encode("UTF-16", invalid: :replace, replace: '?').encode("UTF-8")
  end

  def parse_meta
    meta_content = File.read(meta)
    @parsed_meta = meta_content.split("\n").collect do |e|
      { e.split(":").first => e.split(":")[1..-1].join(":") }
    end.reduce({}, :merge)
  end

  def determine_status
    if parsed_meta['status'] == 'TO'
      return Status.tle
    elsif parsed_meta['status'] == 'SG'
      return Status.find_runtime_error_by_status_code(parsed_meta['exitsig'])
    elsif parsed_meta['status'] == 'RE'
      return Status.nzec
    elsif parsed_meta['status'] == 'XX'
      return Status.boxerr
    elsif submission.expected_output.nil? || strip_output(submission.expected_output) == strip_output(submission.stdout)
      return Status.ac
    else
      return Status.wa
    end
  end

  def strip_output(output)
    output.split("\n").collect(&:rstrip).join("\n").rstrip
  end
end
