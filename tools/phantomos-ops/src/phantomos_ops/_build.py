# Build stamp.
#
# When run from a checkout (`pipx install -e`, tests), BUILD_TAG stays
# "dev". When packaged via tools/phantomos-ops/build.sh, the build
# script overwrites this file with the git SHA + dirty flag of the
# build host BEFORE invoking shiv, so the resulting zipapp self-reports
# its provenance via `phantomos-ops --version` and the help-overlay's
# About tab.
BUILD_TAG = "dev"
