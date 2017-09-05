#!/bin/bash
# Author: eedugon

# Description: Tool to maintain grafana dashboards configmap for a grafana deployed
#   with kube-prometheus (a tool inside prometheus-operator)
# The tool reads the content of a directory with grafana .json resources
#   that need to be moved into a configmap.
# Based on a configurable size limit, the tool will create 1 or N configmaps
#   to allocate the .json resources (bin packing)

# Other ideas
# Add to configmap one or multiple dashboards
# Remove from configMap one or multiple dashboards
# Update ConfigMap in a cluster
# Check and import updates of main public dashboards into templates directory

# Other posibilities
# accept variables to come from environment (DATA_SIZE_LIMIT, OUTPUT_FILE) instead of parameters
# accept --size-limit or --output-file parameters

#
# Basic Functions
#
echoSyntax() {
  echo
  echo "Syntax: $(basename $0) [--apply]"
}

# Configuration
#
# Main Variables
#
# Apply changes --> environment allowed
test -z "$APPLY_CONFIGMAP" && APPLY_CONFIGMAP="false"
# Namespace: currently hardcoded
NAMESPACE="monitoring"

# Size limit --> environment set allowed
test -z "$DATA_SIZE_LIMIT" && DATA_SIZE_LIMIT="240000" # in bytes

# Changes type: in case of problems with k8s configmaps, try replace. Should be apply
test -z "$APPLY_TYPE" && APPLY_TYPE="apply"

# Input values verification
echo "$DATA_SIZE_LIMIT" | grep -q "^[0-9]\+$" || { echo "ERROR: Incorrect value for DATA_SIZE_LIMIT: $DATA_SIZE_LIMIT. Number expected"; exit 1; }
test "$APPLY_TYPE" != "create" && test "$APPLY_TYPE" != "apply" && test "$APPLY_TYPE" != "replace" && { echo "Unexpected APPLY_TYPE: $APPLY_TYPE"; exit 1; }

# Other vars (do not change them)
DATE_EXEC="$(date "+%Y-%m-%d-%H%M%S")"
BIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TOOL_HOME="$(dirname $BIN_DIR)"
SCRIPT_BASE=`basename $0 | sed "s/\.[Ss][Hh]//"`
# echo "Debug: $TOOL_HOMELIB_DIR and $BIN_DIR"
LIB_DIR="$TOOL_HOME/lib"
TEMPLATES_DIR="$TOOL_HOME/templates"
DASHBOARDS_DIR="$TEMPLATES_DIR/grafana-dashboards"

DASHBOARD_HEADER_FILE="$TEMPLATES_DIR/dashboard.header"
DASHBOARD_FOOT_FILE="$TEMPLATES_DIR/dashboard.foot"
CONFIGMAP_HEADER="$TEMPLATES_DIR/ConfigMap.header"

OUTPUT_BASE_DIR="$TOOL_HOME/output"
OUTPUT_FILE="$OUTPUT_BASE_DIR/grafana-dashboards-configMap-$DATE_EXEC.yaml"

if [[ "$OSTYPE" == "darwin"* ]]; then
  STAT_PARAM="-f %z"
else
  STAT_PARAM="-c%s"
fi
#
# Main Functions
#
addConfigMapHeader() {
  # If a parameter is provided it will be used as the configmap index.
  # If no parameter is provided, the name will be kept
  test "$#" -le 1 || { echo "# INTERNAL ERROR: Wrong call to function addConfigMapHeader"; return 1; }
  local id="$1"

  if [ "$id" ]; then
    cat "$CONFIGMAP_HEADER" | sed "s/name: grafana-dashboards/name: grafana-dashboards-$id/"
  else
    cat "$CONFIGMAP_HEADER"
  fi
}

addFilesToConfigMap() {

  test "$#" -ge 1 || { echo "# INTERNAL ERROR: Wrong call to function addFilesToConfigMap"; return 1; }
  local files="$@"
  local file=""

  for file in $files; do
    # detection of type (dashboard or datasource)
    type=""
    basename "$file" | grep -q "\-datasource" && type="datasource"
    basename "$file" | grep -q "\-dashboard" && type="dashboard"
    test "$type" || { echo "# ERROR: Unrecognized file type: $(basename $file)"; return 1; }

    #echo "# Processing $type $file"
    # Indent 2
    echo "  $(basename $file): |+"

    # Dashboard header: No indent needed
    test "$type" = "dashboard" && cat $DASHBOARD_HEADER_FILE

    # File content: Indent 4
    cat $file | sed "s/^/    /"

    # Dashboard foot
    test "$type" = "dashboard" && cat $DASHBOARD_FOOT_FILE
  done
  echo "---"
  return 0
}

initialize-bin-pack() {
  # We separate initialization to reuse the bin-pack for different sets of files.
  n="0"
  to_process=""
  bytes_to_process="0"
  total_files_processed="0"
  total_configmaps_created="0"
}

bin-pack-files() {
  # Algorithm:
  # We process the files with no special order consideration
  # We create a queue of "files to add to configmap" called "to_process"
  # Size of the file is analyzed to determine if it can be added to the queue or not.
  # the max size of the queue is limited by DATA_SIZE_LIMIT
  # while there's room available in the queue we add files.
  # when there's no room we create a configmap with the members of the queue
  #  before adding the file to the queue.

  # Counters initialization is not in the scope of this function
  local file=""

  for file in $@; do
#    echo "debug: Processing file $(basename $file)"

    file_size_bytes="$(stat $STAT_PARAM "$file")"

    # If the file is bigger than the configured limit we skip it file
    if [ "$file_size_bytes" -gt "$DATA_SIZE_LIMIT" ]; then
      echo "ERROR: File $(basename $file) bigger than size limit: $DATA_SIZE_LIMIT ($file_size_bytes). Skipping"
      continue
    fi
    (( total_files_processed++ ))

    if test "$(expr "$bytes_to_process" + "$file_size_bytes")" -le "$DATA_SIZE_LIMIT"; then
      # We have room to include the file in the configmap
      test "$to_process" && to_process="$to_process $file" || to_process="$file"
      (( bytes_to_process = bytes_to_process + file_size_bytes ))
      echo "# File $(basename $file) : added to queue"
    else
      # There's no room to add this file to the queue. so we process what we have and add the file to the queue
      if [ "$to_process" ]; then
        echo
        echo "# Size limit ($DATA_SIZE_LIMIT) reached. Processing queue with $bytes_to_process bytes. Creating configmap with id $n"
        echo
        # Create a new configmap
        addConfigMapHeader $n >> $OUTPUT_FILE || { echo "ERROR in call to addConfigMapHeader function"; exit 1; }
        addFilesToConfigMap $to_process >> $OUTPUT_FILE || { echo "ERROR in call to addFilesToConfigMap function"; exit 1; }
        # Initialize variables with info about file not processed
        (( total_configmaps_created++ ))
        (( n++ ))
        to_process="$file"
        bytes_to_process="$file_size_bytes"
        echo "# File $(basename $file) : added to queue"
      else
        # based on the algorithm the queue should never be empty if we reach this part of the code
        # if this happens maybe bytes_to_process was not aligned with the queue (to_process)
        echo "ERROR (unexpected)"
      fi
    fi
  done
}

# Some variables checks...
test ! -d "$OUTPUT_BASE_DIR" && { echo "ERROR: missing directory $OUTPUT_BASE_DIR"; exit 58; }
test ! -d "$TEMPLATES_DIR" && { echo "ERROR: missing templates directory $TEMPLATES_DIR"; exit 60; }

test -f "$DASHBOARD_FOOT_FILE" || { echo "Template $DASHBOARD_FOOT_FILE not found"; exit 101; }
test -f "$DASHBOARD_HEADER_FILE" || { echo "Template $DASHBOARD_HEADER_FILE not found"; exit 101; }
test -f "$CONFIGMAP_HEADER" || { echo "Template $CONFIGMAP_HEADER not found"; exit 101; }

# Initial checks
test -f "$OUTPUT_FILE" && { echo "ERROR: Output file already exists: $OUTPUT_FILE"; exit 1; }

touch $OUTPUT_FILE || { echo "ERROR: Unable to create or modify $OUTPUT_FILE"; exit 1; }

# Main code start
echo "# Starting execution of $SCRIPT_BASE on $DATE_EXEC"
echo "# Configured size limit: $DATA_SIZE_LIMIT bytes"
echo "# Grafna input dashboards and datasources will be read from: $DASHBOARDS_DIR"
echo "# Grafana Dashboards ConfigMap will be created into file:"
echo "$OUTPUT_FILE"
echo

# Loop variables initialization
initialize-bin-pack

# Process dashboards
bin-pack-files $(find $DASHBOARDS_DIR -maxdepth 1 -type f -name "*-dashboard.json")

# Continue processing datasources (maintaining the same queue)
bin-pack-files $(find $DASHBOARDS_DIR -maxdepth 1 -type f -name "*-datasource.json" )

# Processing remaining data in the queue (or unique)
if [ "$to_process" ]; then
  if [ "$n" -eq 0 ]; then
    echo
    echo "# Size limit not reached ($bytes_to_process). Adding all files into basic configmap"
    echo
    addConfigMapHeader >> $OUTPUT_FILE || { echo "ERROR in call to addConfigMapHeader function"; exit 1; }
  else
    echo
    echo "# Size limit not reached ($bytes_to_process). Adding remaining files into configmap with id $n"
    echo
    addConfigMapHeader $n >> $OUTPUT_FILE || { echo "ERROR in call to addConfigMapHeader function"; exit 1; }
  fi
  addFilesToConfigMap $to_process >> $OUTPUT_FILE || { echo "ERROR in call to addFilesToConfigMap function"; exit 1; }
  (( total_configmaps_created++ ))
fi

echo "# Process completed, configmap created: $(basename $OUTPUT_FILE)"
echo "# Summary"
echo "# Total files processed: $total_files_processed"
echo "# Total amount of ConfigMaps inside the manifest: $total_configmaps_created"

# If output file is empty we can delete it and exit
test ! -s "$OUTPUT_FILE" && { echo "# Configmap empty, deleting file"; rm $OUTPUT_FILE; exit 0; }

if [ "$APPLY_CONFIGMAP" = "true" ]; then
  test -x "$(which kubectl)" || { echo "ERROR: kubectl command not available. Apply configmap not possible"; exit 1; }
  echo
  if kubectl -n $NAMESPACE $APPLY_TYPE -f "$OUTPUT_FILE"; then
    echo
    echo "# ConfigMap updated. Wait until grafana-watcher applies the changes and reloads the dashboards."
  else
    echo
    echo "ERROR APPLYING CONFIGURATION. Check yaml file"
    echo "$OUTPUT_FILE"
  fi
else
  echo
  echo "# To apply the new configMap to your k8s system do something like:"
  echo "kubectl -n monitoring apply -f $(basename $OUTPUT_FILE)"
  echo
fi
