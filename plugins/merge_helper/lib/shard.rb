module Jetpants
  class Shard
    # Runs queries against a slave in the pool to verify sharding key values
    def validate_shard_data
      tables = Table.from_config 'sharded_tables'
      table_statuses = {}
      tables.limited_concurrent_map(8) { |table|
        table.sharding_keys.each do |col|
          range_sql = table.sql_range_check col, @min_id, @max_id

          # use a standby slave, since this query will be very heavy and these shards are live
          db = standby_slaves.last
          result = db.query_return_array range_sql

          if result.first.values.first > 0
            table_statuses[table] = :invalid
          else
            table_statuses[table] = :valid
          end
        end
      }

      table_statuses
    end

    # Generate a list of filenames for exported data
    def table_export_filenames(full_path = true, tables = false)
      export_filenames = []
      tables = Table.from_config 'sharded_tables' unless tables
      export_filenames = tables.map { |table| table.export_filenames(@min_id, @max_id) }.flatten

      export_filenames.map!{ |filename| File.basename filename } unless full_path

      export_filenames
    end

    # Sets up an aggregate node and new shard master with data from two shards, returned with replication stopped
    # This will take two standby slaves, pause replication, export their data, ship it to the aggregate
    # node and new master, import the data, and set up multi-source replication to the shards being merged
    def self.set_up_aggregate_node(shards_to_merge, aggregate_node, new_shard_master)
      # validation
      shards_to_merge.each do |shard|
        raise "Attempting to create an aggregate node with a non-shard!" unless shard.is_a? Shard
      end
      raise "Attempting to set up aggregation on a non-aggregate node!" unless aggregate_node.aggregator?
      raise "Attempting to set up aggregation on a node that is already aggregating!" unless aggregate_node.aggregating_nodes.empty?
      raise "Invalid new master node!" unless new_shard_master.is_a? DB
      raise "New shard master already has a pool!" unless new_shard_master.pool.nil?

      data_nodes = [ new_shard_master, aggregate_node ]

      # settings to improve import speed
      data_nodes.concurrent_each do |db|
        db.restart_mysql '--skip-log-bin', '--skip-log-slave-updates', '--innodb-autoinc-lock-mode=2', '--skip-slave-start', '--innodb_flush_log_at_trx_commit=2', '--innodb-doublewrite=0'
      end

      # create and ship schema
      slave = shards_to_merge.last.standby_slaves.last
      data_nodes.each do |db|
        slave.ship_schema_to db
        db.import_schemata!
      end

      # grab slave list to export data
      slaves_to_replicate = shards_to_merge.map { |shard| shard.standby_slaves.last }

      # sharded table list to ship
      tables = Plugin::MergeHelper.tables_to_merge

      # data export counts for validation later
      export_counts = {}
      slave_coords = {}

      # asynchronously export data on all slaves
      slaves_to_replicate.concurrent_map { |slave|
        # these get cleaned up further down after replication is set up
        slave.disable_monitoring
        slave.stop_query_killer
        slave.pause_replication

        slave.export_data tables, slave.pool.min_id, slave.pool.max_id
        # record export counts for validation
        export_counts[slave] = slave.import_export_counts
        # retain coords to set up replication hierarchy
        file, pos = slave.binlog_coordinates
        slave_coords[slave] = { :log_file => file, :log_pos => pos }
      }

      # ship and load data from each slave
      slaves_to_replicate.map { |slave|
        # transfer data files, this will output a large list of file names
        slave.fast_copy_chain(
          Jetpants.export_location,
          data_nodes,
          port: 3307,
          files: slave.pool.table_export_filenames(full_path = false, tables),
          overwrite: true
        )
        # clean up files on origin slave
        slave.pool.table_export_filenames(full_path = true, tables).map { |file|
          slave.ssh_cmd("rm -f #{file}")
        }
        # restart origin slave replication
        slave.resume_replication
        slave.catch_up_to_master
        slave.enable_monitoring
        slave.start_query_killer
      }

      # import data in a separate loop, as we want to leave the origin slaves
      # in a non-replicating state for as little time as possible
      slaves_to_replicate.map { |slave| 
        # load data and inject export counts from earlier for validation
        data_nodes.concurrent_map { |db|
          db.inject_counts export_counts[slave]
          db.import_data tables, slave.pool.min_id, slave.pool.max_id
        }
      }

      # clear out earlier import options
      data_nodes.concurrent_each do |db|
        db.restart_mysql "--skip-slave-start"
      end

      # set up replication hierarchy
      slaves_to_replicate.each do |slave|
        aggregate_node.add_node_to_aggregate slave, slave_coords[slave]
      end
      new_shard_master.change_master_to aggregate_node
    end

    def combined_shard
      Jetpants.shards.select { |shard| ( 
        shard.min_id.to_i <= @min_id.to_i \
        && shard.max_id.to_i >= @max_id.to_i \
        && shard.max_id != 'INFINITY' \
        && @max_id != 'INFINITY' \
        && shard.state == :initializing \
        && shard != self
      )}.first
    end

    def prepare_for_merged_reads
      @state = :merging
      sync_configuration
    end

    def prepare_for_merged_writes
      @state = :deprecated
      sync_configuration
    end

    def decomission!
      @state = :decommissioned
    end

    def in_config?
      [:merging, :ready, :child, :needs_cleanup, :read_only, :offline].include? @state
    end
  end
end
