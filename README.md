# Grafana Dashboards Configmap Generator

## Description:
Tool to maintain grafana dashboards' configmap for a grafana deployed with kube-prometheus (a tool inside prometheus-operator).

The tool reads the content of a directory with grafana .json resources (dashboards and datasources) and creates a manifest file under output/ directory with all the content from the files in a Kubernetes ConfigMap format.

Based on a configurable size limit, the tool will create 1 or N configmaps to allocate the .json resources (bin packing). If the limit is reached then the configmaps generated will have names like grafana-dashboards-0, grafana-dashboards-1, etc, and if the limit is not reached the configmap generated will be called "grafana-dashboards".

The tool accepts `APPLY_CONFIGMAP` (default to false) and `APPLY_TYPE` (defaults to "apply") flags to also apply the generated configmap into monitoring namespace. (Note: Consider using `replace` instead of `apply` if annotations limit error is raised by kubernetes).

## Usage

Just execute the .sh under bin/ directory. The output will be placed in the output/ directory.

Examples:
```bash
$ ./grafana_dashboards_generate.sh
$ APPLY_CONFIGMAP="true" APPLY_TYPE="replace" grafana-dashboards-configmap-generator/bin/grafana_dashboards_generate.sh
$ DATA_SIZE_LIMIT="1000000" grafana-dashboards-configmap/bin/grafana_dashboards_generate.sh
```

## Configuration and options

* Put the json files you want to pack in the templates/grafana-dashboards/ directory
* Size limit default is 240000 bytes due to the annotations size limit in kubernetes of 256KB.
* set environment variables `DATA_SIZE_LIMIT`, `APPLY_CONFIGMAP` and `APPLY_TYPE` if you don't want to use the default values.

## Other ideas
* Add to configmap one or multiple dashboards
* Remove from configMap one or multiple dashboards
* Update ConfigMap in a cluster
* Backup running configmaps
* Check and import updates of main public dashboards (prometheus-operator/contrib/kube-prometheus/assets/grafana/) into templates directory.
* option to receive output_file name and overwrite if already exists

