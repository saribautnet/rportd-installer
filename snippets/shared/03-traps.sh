on_fail() {
  echo ""
  echo "We are very sorry. Something went wrong."
  echo "Command '$previous_command' exited erroneous on line $1."
  echo "Try executing this installer or update with bash debug mode."
  echo "  bash -x $0"
  echo ""
  echo "If you need help solving issues ask for help on"
  echo "https://github.com/cloudradar-monitoring/rportd-installer/discussions/categories/help-needed"
  echo ""
}
debug() {
  previous_command=$this_command
  this_command=$BASH_COMMAND
}
trap 'debug' DEBUG
trap 'on_fail ${LINENO}' ERR
