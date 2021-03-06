module Rebi
  class ZipHelper

    include Rebi::Log

    attr_reader :env_conf, :opts

    def initialize env_conf,opts={}
      @env_conf = env_conf
      @opts = opts
      # raise Rebi::Error::NoGit.new("Not a git repository") unless git?
    end

    def staged?
      opts[:staged]
    end

    def git?
      `git status 2>&1`
      $?.success?
    end

    def ls_files
      `git ls-files 2>&1`.split("\n")
    end

    def raw_zip_archive
      tmp_file = Tempfile.new("git_archive")
      if !git? || ebignore?
        Zip::File.open(tmp_file.path, Zip::File::CREATE) do |z|
          spec = ebignore_spec
          Dir.glob("**/*").each do |f|
            next if spec.match f
            if File.directory?(f)
              z.mkdir f unless z.find_entry f
            else
              z.add f, f
            end
          end
        end
      else
        commit_id = staged? ? `git write-tree`.chomp : "HEAD"
        system "git archive --format=zip #{commit_id} > #{tmp_file.path}"
      end
      return tmp_file
    end

    def version_label
      git? ? `git describe --always --abbrev=8`.chomp : SecureRandom.hex[0, 8]
    end

    def message
      git? ? `git log --oneline -1`.chomp.split(" ")[1..-1].join(" ")[0..190] : "Deploy #{Time.now.strftime("%Y/%m/%d %H:%M")}"
    end

    # Create zip archivement
    def gen
      log("Creating zip archivement", env_conf.name)
      start = Time.now
      ebextensions = env_conf.ebextensions
      tmp_file = raw_zip_archive
      tmp_folder = Dir.mktmpdir
      Zip::File.open(tmp_file.path) do |z|
        ebextensions.each do |ex_folder|
          z.remove_folder ex_folder unless ex_folder == ".ebextensions"
          Dir.glob("#{ex_folder}/*.config*") do |fname|
            next unless File.file?(fname)

            basename = File.basename(fname)
            source_file = fname

            if fname.match(/\.erb$/)
              next unless y = YAML::load(ErbHelper.new(File.read(fname), env_conf).result)
              basename = basename.gsub(/\.erb$/,'')
              source_file = "#{tmp_folder}/#{basename}"
              File.open(source_file, 'w') do |f|
                f.write y.to_yaml
              end
            end

            target = ".ebextensions/#{basename}"

            z.remove target if z.find_entry target
            z.remove fname if z.find_entry fname
            z.add target, source_file
          end
        end
        dockerrun_file = env_conf.dockerrun || "Dockerrun.aws.json"

        if File.exists?(dockerrun_file)
          dockerrun = JSON.parse ErbHelper.new(File.read(dockerrun_file), env_conf).result
          tmp_dockerrun = "#{tmp_folder}/Dockerrun.aws.json"
          File.open(tmp_dockerrun, 'w') do |f|
            f.write dockerrun.to_json
          end
          z.remove env_conf.dockerrun if z.find_entry env_conf.dockerrun
          z.remove "Dockerrun.aws.json" if z.find_entry "Dockerrun.aws.json"
          z.add "Dockerrun.aws.json", tmp_dockerrun
        end

      end

      FileUtils.rm_rf tmp_folder
      log("Zip was created in: #{Time.now - start}s", env_conf.name)
      return {
        label: Time.now.strftime("app_#{env_conf.name}_#{version_label}_%Y%m%d_%H%M%S"),
        file: File.open(tmp_file.path),
        message: message,
      }
    end

    def ebignore_spec
      if ebignore?
        path_spec = PathSpec.from_filename(ebignore)
        path_spec.add(".git")
        return path_spec
      else
        return PathSpec.new(".git")
      end
    end

    def ebignore?
      File.exist?(ebignore)
    end

    def ebignore
      env_conf.ebignore
    end
  end
end

module Zip
  class File
    def remove_folder fname
      if folder = find_entry(fname)
        remove folder if folder.directory?
      end
      glob("#{fname}/**/*").each do |f|
        remove f
      end
    end
  end
end
