#!/usr/bin/env bash

cache_copy() {
  rel_dir=$1
  from_dir=$2
  to_dir=$3
  rm -rf $to_dir/$rel_dir
  if [ -d $from_dir/$rel_dir ]; then
    mkdir -p $to_dir/$rel_dir
    cp -pr $from_dir/$rel_dir/. $to_dir/$rel_dir
  fi
}

# Load config vars into environment
export_env_dir() {
  env_dir=$1
  whitelist_regex=${2:-''}
  blacklist_regex=${3:-'^(PATH|GIT_DIR|CPATH|CPPATH|LD_PRELOAD|LIBRARY_PATH|JAVA_OPTS)$'}
  if [ -d "$env_dir" ]; then
    for e in $(ls $env_dir); do
      echo "$e" | grep -E "$whitelist_regex" | grep -qvE "$blacklist_regex" &&
      export "$e=$(cat $env_dir/$e)"
      :
    done
  fi
}

compile_cljs() {
  # fail fast
  set -e

  # parse args
  BUILD_DIR=$1/cljs
  CACHE_DIR=$2
  ENV_DIR=$3

  export_env_dir $ENV_DIR

  # Load common JVM functionality from https://github.com/heroku/heroku-buildpack-jvm-common
  JVM_COMMON_BUILDPACK=${JVM_COMMON_BUILDPACK:-https://codon-buildpacks.s3.amazonaws.com/buildpacks/heroku/jvm-common.tgz}
  mkdir -p /tmp/jvm-common
  curl --retry 3 --silent --location $JVM_COMMON_BUILDPACK | tar xzm -C /tmp/jvm-common --strip-components=1
  . /tmp/jvm-common/bin/util
  . /tmp/jvm-common/bin/java
  install_java_with_overlay ${BUILD_DIR}

  # Determine Leiningen version
  LEIN_VERSION="2.5.3"
  LEIN_BIN_SOURCE="$(dirname $0)/../opt/lein2"
  LEIN_BUILD_TASK=${LEIN_BUILD_TASK:-"cljsbuild once prod"}

  # install leiningen jar
  LEIN_JAR_URL="https://lang-jvm.s3.amazonaws.com/leiningen-$LEIN_VERSION-standalone.jar"
  LEIN_JAR_CACHE_PATH="$CACHE_DIR/leiningen-$LEIN_VERSION-standalone.jar"
  LEIN_JAR_SLUG_PATH="$BUILD_DIR/.lein/leiningen-$LEIN_VERSION-standalone.jar"

  if [ ! -r "$LEIN_JAR_CACHE_PATH" ]; then
    echo "-----> Installing Leiningen"
    echo "       Downloading: leiningen-$LEIN_VERSION-standalone.jar"
    mkdir -p $(dirname $LEIN_JAR_CACHE_PATH)
    curl --retry 3 --silent --show-error --max-time 120 -L -o "$LEIN_JAR_CACHE_PATH" $LEIN_JAR_URL
  else
    echo "-----> Using cached Leiningen $LEIN_VERSION"
  fi

  mkdir -p "$BUILD_DIR/.lein"
  cp "$LEIN_JAR_CACHE_PATH" "$LEIN_JAR_SLUG_PATH"

  # install rlwrap binary on lein 1.x
  if [ "$RLWRAP" = "yes" ]; then
    RLWRAP_BIN_URL="https://lang-jvm.s3.amazonaws.com/rlwrap-0.3.7"
    RLWRAP_BIN_PATH=$BUILD_DIR"/.lein/bin/rlwrap"
    echo "       Downloading: rlwrap-0.3.7"
    mkdir -p $(dirname $RLWRAP_BIN_PATH)
    curl --retry 3 --silent --show-error --max-time 60 -L -o $RLWRAP_BIN_PATH $RLWRAP_BIN_URL
    chmod +x $RLWRAP_BIN_PATH
  fi

  # install lein script
  LEIN_BIN_PATH=$BUILD_DIR"/.lein/bin/lein"
  echo "       Writing: lein script"
  mkdir -p $(dirname $LEIN_BIN_PATH)
  cp $LEIN_BIN_SOURCE $LEIN_BIN_PATH
  sed -i s/##LEIN_VERSION##/$LEIN_VERSION/ $LEIN_BIN_PATH

  # create user-level profiles
  LEIN_PROFILES_SOURCE="$(dirname $0)/../opt/profiles.clj"
  cp -n $LEIN_PROFILES_SOURCE "$BUILD_DIR/.lein/profiles.clj"

  # unpack existing cache
  CACHED_DIRS=".m2 node_modules"
  for DIR in $CACHED_DIRS; do
    if [ ! -d $BUILD_DIR/$DIR ]; then
      cache_copy $DIR $CACHE_DIR $BUILD_DIR
    fi
  done

  echo "-----> Building with Leiningen"

  # extract environment
  if [ -d "$ENV_DIR" ]; then
      # if BUILD_CONFIG_WHITELIST is set, read it to know which configs to export
      if [ -r $ENV_DIR/BUILD_CONFIG_WHITELIST ]; then
          for e in $(cat $ENV_DIR/BUILD_CONFIG_WHITELIST); do
              export "$e=$(cat $ENV_DIR/$e)"
          done
      # otherwise default BUILD_CONFIG_WHITELIST to just private repo creds
      else
          for e in LEIN_USERNAME LEIN_PASSWORD LEIN_PASSPHRASE; do
              if [ -r $ENV_DIR/$e ]; then
                  export "$e=$(cat $ENV_DIR/$e)"
              fi
          done
      fi
  fi

  # Calculate build command
  if [ "$BUILD_COMMAND" = "" ]; then
      if [ -x $BUILD_DIR/bin/build ]; then
          echo "       Found bin/build; running it instead of default lein invocation."
          BUILD_COMMAND=bin/build
      else
          BUILD_COMMAND="lein $LEIN_BUILD_TASK"
      fi
  fi

  echo "       Running: $BUILD_COMMAND"

  cd $BUILD_DIR
  PATH=.lein/bin:$PATH JVM_OPTS="-Xmx600m" \
    LEIN_JVM_OPTS="-Xmx400m -Duser.home=$BUILD_DIR" \
    $BUILD_COMMAND 2>&1 | sed -u 's/^/       /'
  if [ "${PIPESTATUS[*]}" != "0 0" ]; then
    echo " !     Failed to build."
    exit 1
  fi

  # repack cache with new assets
  mkdir -p $CACHE_DIR
  for DIR in $CACHED_DIRS; do
    cache_copy $DIR $BUILD_DIR $CACHE_DIR
  done

}