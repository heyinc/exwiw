# frozen_string_literal: true

require 'erb'

module Exwiw
  class AfterInsertHook
    def self.run(path:, cli_options:, output_dir:, next_idx:, output_extension:, logger:)
      ext = File.extname(path)
      idx_str = next_idx.to_s.rjust(3, '0')
      output_path = File.join(output_dir, "insert-#{idx_str}-after_insert.#{output_extension}")

      if ext == '.rb'
        run_ruby(path: path, cli_options: cli_options, output_path: output_path, logger: logger)
      else
        run_shell(path: path, cli_options: cli_options, output_dir: output_dir, logger: logger)
      end
    end

    def self.run_ruby(path:, cli_options:, output_path:, logger:)
      ctx = Context.new(cli_options)
      ctx.instance_eval(File.read(path), path)
      content = ctx.collected.join("\n")
      if content.empty?
        logger.info("After-insert hook produced no output; skipping file write.")
        return
      end
      File.write(output_path, content)
      logger.info("Wrote after-insert hook output to #{output_path}")
    end

    def self.run_shell(path:, cli_options:, output_dir:, logger:)
      env = {
        'EXWIW_OUTPUT_DIR'       => output_dir,
        'EXWIW_CONFIG_DIR'       => cli_options[:config_dir].to_s,
        'EXWIW_DATABASE_ADAPTER' => cli_options[:database_adapter].to_s,
        'EXWIW_DATABASE_HOST'    => cli_options[:database_host].to_s,
        'EXWIW_DATABASE_PORT'    => cli_options[:database_port].to_s,
        'EXWIW_DATABASE_USER'    => cli_options[:database_user].to_s,
        'EXWIW_DATABASE_NAME'    => cli_options[:database_name].to_s,
        'EXWIW_TARGET_TABLE'     => cli_options[:target_table].to_s,
        'EXWIW_IDS'              => Array(cli_options[:ids]).join(','),
        'EXWIW_OUTPUT_FORMAT'    => cli_options[:output_format].to_s,
      }
      logger.info("Running after-insert shell hook: #{path}")
      ok = system(env, path)
      raise "after-insert shell hook failed: #{path}" unless ok
    end

    class Context
      attr_reader :cli_options, :collected

      def initialize(cli_options)
        @cli_options = cli_options
        @collected = []
      end

      def insert_sql(template)
        @collected << ERB.new(template, trim_mode: '-').result(binding)
      end
      alias_method :insert_jsonl, :insert_sql
    end
  end
end
