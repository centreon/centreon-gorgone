# Migrate from Centreon *centcore*

To build a configuration file based on */etc/centreon/conf.pm*, execute the following command line.

If using package:

```bash
$ perl /usr/local/bin/gorgone_config_init.pl
2019-09-30 11:00:00 - INFO - file '/etc/centreon-gorgone/config.yaml' created success
```

If using sources:

```bash
$ perl ./contrib/gorgone_config_init.pl
2019-09-30 11:00:00 - INFO - file '/etc/centreon-gorgone/config.yaml' created success
```

As a result the following configurations files will be created in the */etc/centreon/* folder:

The *config.yaml*
```yaml
name: config.yaml
description: Configuration for Central server
configuration: !include config.d/*.yaml
```

The *config.d/10-database.yaml* for the database:

```yaml
database:
  db_centreon:
    dsn: "mysql:host=localhost;port=3306;dbname=centreon"
    username: "centreon"
    password: "centreon"
  db_centstorage:
    dsn: "mysql:host=localhost;port=3306;dbname=centreon_storage"
    username: "centreon"
    password: "centreon"
```

In *config.d/20-gorgoned.yaml* for the core

```yaml
gorgone:
  gorgonecore:
    privkey: "/var/spool/centreon/.gorgone/rsakey.priv.pem"
    pubkey: "/var/spool/centreon/.gorgone/rsakey.pub.pem"
  modules:
    - name: httpserver
      package: gorgone::modules::core::httpserver::hooks
      enable: true
      address: 0.0.0.0
      port: 8085
      ssl: true
      ssl_cert_file: /etc/pki/tls/certs/server-cert.pem
      ssl_key_file: /etc/pki/tls/server-key.pem
      auth:
        user: admin
        password: password

    - name: action
      package: gorgone::modules::core::action::hooks
      enable: true
      
    - name: cron
      package: gorgone::modules::core::cron::hooks
      enable: false
      cron: !include cron.d/*.yaml

    - name: proxy
      package: gorgone::modules::core::proxy::hooks
      enable: true
  
    - name: legacycmd
      package: gorgone::modules::centreon::legacycmd::hooks
      enable: true
      cmd_file: "/var/lib/centreon/centcore.cmd"
      cache_dir: "/var/cache/centreon/"
      cache_dir_trap: "/etc/snmp/centreon_traps/"
      remote_dir: "/var/lib/centreon/remote-data/"

    - name: engine
      package: "gorgone::modules::centreon::engine::hooks"
      enable: true
      command_file: "/var/lib/centreon-engine/rw/centengine.cmd"
      
    - name: pollers
      package: gorgone::modules::centreon::pollers::hooks
      enable: true

    - name: broker
      package: "gorgone::modules::centreon::broker::hooks"
      enable: true
      cache_dir: "/var/cache/centreon//broker-stats/"
      cron:
        - id: broker_stats
          timespec: "*/2 * * * *"
          action: BROKERSTATS
          parameters:
            timeout: 10
```
