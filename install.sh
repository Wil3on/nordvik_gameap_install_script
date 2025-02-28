#!/usr/bin/env bash

shopt -s dotglob
[ "${DEBUG:-}" == 'true' ] && set -x
export DEBIAN_FRONTEND="noninteractive"

trap ctrl_c INT

function ctrl_c() {
    echo
    echo "Exiting..."
    echo
    exit 130
}

parse_options () 
{
    for i in "$@"
    do
        case $i in
            -h|--help)
                show_help
                exit 0
            ;;
            --path=*)
                gameap_path=${i#*=}
                shift

                if [[ ! -s "${gameap_path}" ]]; then
                    mkdir -p ${gameap_path}

                    if [ "$?" -ne "0" ]; then
                        echo "Unable to make directory: ${gameap_path}." >> /dev/stderr
                        exit 1
                    fi
                fi
            ;;
            --host=*)
                gameap_host=${i#*=}
                shift
            ;;
            --web-server=*)
                web_selected="${i#*=}"
                shift
            ;;
            --database=*)
                db_selected="${i#*=}"
                shift
            ;;
            --github)
                from_github=1
            ;;
            --develop)
                develop=1
            ;;
            --upgrade)
                upgrade=1
            ;;
        esac
    done
}

show_help ()
{
    echo
    echo "GameAP web auto installator"
}

_detect_source_repository()
{
  source_repository=""
  local repositories=("https://packages.hz1.gameap.io" "https://packages.gameap.ru")

  for repository in "${repositories[@]}"; do
    if curl -s -o /dev/null --connect-timeout 5 --max-time 10 -I -w "%{http_code}" "${repository}" | grep -q "200"; then
      source_repository=${repository}
      return 0
    fi
  done

  return 1
}

update_packages_list ()
{
    echo
    echo -n "Running apt-get update... "

    apt-get update &> /dev/null

    if [ "$?" -ne "0" ]; then
        echo "Unable to update apt" >> /dev/stderr
        exit 1
    fi

    echo "done."
    echo
}

install_packages ()
{
    packages=$@

    echo
    echo -n "Installing ${packages}... "
    apt-get install -y $packages

    if [ "$?" -ne "0" ]; then
        echo "Unable to install ${packages}." >> /dev/stderr
        echo "Package installation aborted." >> /dev/stderr
        exit 1
    fi

    echo "done."
    echo
}

add_gpg_key ()
{
    gpg_key_url=$1
    curl -SfL "${gpg_key_url}" 2> /dev/null | apt-key add - &>/dev/null

    if [ "$?" -ne "0" ]; then
      echo "Unable to add GPG key!" >> /dev/stderr
      exit 1
    fi
}

generate_password()
{
    echo $(tr -cd 'a-zA-Z0-9' < /dev/urandom | fold -w18 | head -n1)
}

is_ipv4()
{
    if [[ ${1} =~ ^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; then
        return 0
    else
        return 1
    fi
}

unknown_os ()
{
    echo "Unfortunately, your operating system distribution and version are not supported by this script."
    exit 2
}

detect_os ()
{
    os=""
    dist=""

    if [[ -e /etc/lsb-release ]]; then
        . /etc/lsb-release

        if [[ "${ID:-}" = "raspbian" ]]; then
            os=${ID}
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        else
            os=${DISTRIB_ID}
            dist=${DISTRIB_CODENAME}

            if [ -z "$dist" ]; then
                dist=${DISTRIB_RELEASE}
            fi
        fi
    elif [[ -e /etc/os-release ]]; then
        . /etc/os-release

        os="${ID:-}"

        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            dist=${VERSION_CODENAME:-}
        elif [[ -n "${VERSION_ID:-}" ]]; then
            dist=${VERSION_ID:-}
        fi

    elif [[ -n "$(command -v lsb_release > /dev/null 2>&1)" ]]; then
        dist=$(lsb_release -c | cut -f2)
        os=$(lsb_release -i | cut -f2 | awk '{ print tolower($1) }')
    fi

    if [[ -z "$dist" ]] && [[ -e /etc/debian_version ]]; then
        os=$(cat /etc/issue | head -1 | awk '{ print tolower($1) }')
        if grep -q '/' /etc/debian_version; then
            dist=$(cut --delimiter='/' -f1 /etc/debian_version)
        else
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        fi
    fi

    if [[ -z "$dist" ]]; then
        unknown_os
    fi

    if [[ "${os}" = "debian" ]]; then
        case $dist in
            6* ) dist="squeeze" ;;
            7* ) dist="wheezy" ;;
            8* ) dist="jessie" ;;
            9* ) dist="stretch" ;;
            10* ) dist="buster" ;;
            11* ) dist="bullseye" ;;
            12* ) dist="bookworm" ;;
        esac
    fi

    # remove whitespace from OS and dist name
    os="${os// /}"
    dist="${dist// /}"

    # lowercase
    os=${os,,}
    dist=${dist,,}

    echo "Detected operating system as $os/$dist."
}

gpg_check ()
{
    echo
    echo "Checking for gpg..."
    if command -v gpg > /dev/null; then
        echo "Detected gpg..."
    else
        echo "Installing gnupg for GPG verification..."
        apt-get install -y gnupg
        if [ "$?" -ne "0" ]; then
        echo "Unable to install GPG! Your base system has a problem; please check your default OS's package repositories because GPG should work." >> /dev/stderr
        echo "Repository installation aborted." >> /dev/stderr
        exit 1
        fi
    fi
}

curl_check ()
{
    echo
    echo "Checking for curl..."

    if command -v curl > /dev/null; then
        echo "Detected curl..."
    else
        echo "Installing curl..."
        apt-get install -q -y curl
        if [[ "$?" -ne "0" ]]; then
        echo "Unable to install curl! Your base system has a problem; please check your default OS's package repositories because curl should work." >> /dev/stderr
        echo "Repository installation aborted." >> /dev/stderr
        exit 1
        fi
    fi
}

get_package_name ()
{
    package=$1

    if [[ "${package}" = "mysql" ]]; then
        if [[ "${os}" = "debian" ]]; then
            package_name="mysql-server"
            case $dist in
                "squeeze" ) package_name="mysql-server" ;;
                "wheezy" ) package_name="mysql-server" ;;
                "jessie" ) package_name="mysql-server" ;;
                "stretch" ) package_name="default-mysql-server" ;;
                "buster" ) package_name="default-mysql-server" ;;
                "bullseye" ) package_name="default-mysql-server" ;;
                "sid" ) package_name="default-mysql-server" ;;
            esac
        elif [[ "${os}" = "ubuntu" ]]; then
            package_name="mysql-server"
        else
            package_name="mysql-server"
        fi
    fi

    echo $package_name
}

add_php_repo ()
{
    if [[ "${os}" = "debian" ]]; then
        add_gpg_key "https://packages.sury.org/php/apt.gpg"
        echo "deb https://packages.sury.org/php/ ${dist} main" | tee /etc/apt/sources.list.d/php.list
    elif [[ "${os}" = "ubuntu" ]]; then
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    fi

    update_packages_list
    php_packages_check 1
}

php_packages_check ()
{
    not_repo=$1
    
    echo
    echo
    echo "Checking for PHP..."

    echo
    echo "Checking for PHP 8.3 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 8.3)" ]]; then
        echo "PHP 8.3 available"
        php_version="8.3"
        return
    fi
    echo "PHP 8.3 not available..."

    echo
    echo "Checking for PHP 8.2 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 8.2)" ]]; then
        echo "PHP 8.2 available"
        php_version="8.2"
        return
    fi
    echo "PHP 8.2 not available..."

    echo
    echo "Checking for PHP 8.1 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 8.1)" ]]; then
        echo "PHP 8.1 available"
        php_version="8.1"
        return
    fi
    echo "PHP 8.1 not available..."

    echo
    echo "Checking for PHP 8.0 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 8.0)" ]]; then
        echo "PHP 8.0 available"
        php_version="8.0"
        return
    fi
    echo "PHP 8.0 not available..."

    echo
    echo "Checking for PHP 7.4 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 7.4)" ]]; then
        echo "PHP 7.4 available"
        php_version="7.4"
        return
    fi
    echo "PHP 7.4 not available..."

    echo
    echo "Checking for PHP 7.3 version available..."

    if [[ ! -z "$(apt-cache policy php | grep 7.3)" ]]; then
        echo "PHP 7.3 available"
        php_version="7.3"
        return
    fi
    echo "PHP 7.3 not available..."

    if [[ -z $not_repo ]]; then
        echo
        echo "Trying to add PHP repo..."
        add_php_repo
    fi
}

install_from_github ()
{
    install_packages git curl jq

    echo
    echo "Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    echo "done"
    
    echo
    echo "Installing NodeJS..."
    # Use the latest LTS version (20.x) instead of the outdated 15.x
    # First try to set up using the NodeSource repository
    if command -v curl > /dev/null; then
        echo "Setting up NodeJS 20.x repository..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update
        echo "Installing nodejs..."
        apt-get install -y nodejs
    else
        # Fallback to Ubuntu's default repository if NodeSource setup fails
        echo "Installing nodejs and npm from default repositories..."
        install_packages nodejs npm
    fi
    
    # Verify the installation
    node_version=$(node -v 2>/dev/null || echo "Node.js not installed")
    npm_version=$(npm -v 2>/dev/null || echo "npm not installed")
    echo "Installed Node.js version: $node_version"
    echo "Installed npm version: $npm_version"
    
    # If NodeJS installation failed, try to use NVM as a last resort
    if [[ "$node_version" == "Node.js not installed" ]]; then
        echo "NodeJS installation from repositories failed. Trying to use NVM..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install 20
            nvm use 20
        fi
    fi
    echo "done"

    # Set repository and branch
    github_repo="https://github.com/Wil3on/gameap"
    git_branch="develop"

    # Get latest release version starting from v1.0.0
    echo "Checking latest release version..."
    latest_version=$(curl -s "https://api.github.com/repos/Wil3on/gameap/releases" | jq -r '[.[] | select(.tag_name >= "v1.0.0")] | sort_by(.published_at) | reverse[0].tag_name')
    
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        echo "Unable to find a release version v1.0.0 or later" >> /dev/stderr
        echo "Falling back to latest commit on develop branch"
        git clone -b $git_branch $github_repo.git $gameap_path
    else
        echo "Found latest release: $latest_version"
        # Clone the repository
        git clone -b $git_branch $github_repo.git $gameap_path
        
        # Checkout the specific tag/release
        cd $gameap_path || exit 1
        git checkout $latest_version
    fi

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to download from GitHub" >> /dev/stderr
        exit 1
    fi

    cd $gameap_path || exit 1

    echo
    echo "Installing Composer packages..."
    echo "This may take a long while..."
    composer install --no-dev --optimize-autoloader &> /dev/null
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to install Composer packages. " >> /dev/stderr
        exit 1
    fi
    echo "done"

    cp .env.example .env

    echo
    echo "Generating encryption key..."
    php artisan key:generate --force
    echo "done"

    echo
    echo "Installing NodeJS packages..."
    npm install &> /dev/null
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to install NodeJS packages. " >> /dev/stderr
        echo "Styles building aborted." >> /dev/stderr
        exit 1
    fi
    echo "done"

    echo
    echo "Building the styles..."
    # Check if 'prod' script exists in package.json, if not use 'build' instead
    if grep -q '"prod":' package.json; then
        npm run prod &> /dev/null
    else
        # Newer projects might use 'build' instead of 'prod'
        npm run build &> /dev/null
    fi
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to build styles. " >> /dev/stderr
        echo "Styles building aborted." >> /dev/stderr
        exit 1
    fi
    echo "done"
}

download_unpack_from_repo ()
{
    cd $gameap_path || exit 1

    echo
    echo "Downloading GameAP archive..."

    curl -SfL "${source_repository}/gameap/latest" \
        --output gameap.tar.gz &> /dev/null
    
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to download GameAP. "
        echo "Installation GameAP aborted."
        exit 1
    fi
    echo "done"

    echo "Unpacking GameAP archive..."
    tar -xvf gameap.tar.gz -C ./ &> /dev/null
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to unpack GameAP. " >> /dev/stderr
        echo "Installation GameAP aborted." >> /dev/stderr
        exit 1
    fi
    echo "done"
    
    cp -r gameap/* ./
    rm -r gameap
    rm gameap.tar.gz
}

install_from_official_repo ()
{
    cd $gameap_path || exit 1

    download_unpack_from_repo

    cp .env.example .env
}

generate_encription_key ()
{
    cd $gameap_path || exit 1
    
    echo "Generating encryption key..."
    php artisan key:generate --force
    
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to generate encription key" >> /dev/stderr
        exit 1
    fi

    echo "done"
}

upgrade_migrate ()
{
    cd $gameap_path || exit 1

    echo
    echo "Migrating database..."
    php artisan migrate

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to migrate database" >> /dev/stderr
        exit 1
    fi
    echo "done"
}

upgrade_postscripts ()
{
    cd $gameap_path || exit 1

    php artisan cache:clear
    php artisan config:cache
    php artisan view:cache
}

upgrade_from_github ()
{
    cd $gameap_path || exit 1

    # Save the current branch and remote URL
    current_remote=$(git config --get remote.origin.url)

    # If the repository is not from the user's GitHub, change it
    if [[ "$current_remote" != "https://github.com/Wil3on/gameap.git" ]]; then
        echo "Changing remote repository to https://github.com/Wil3on/gameap.git..."
        git remote set-url origin https://github.com/Wil3on/gameap.git
        echo "done"
    fi
    
    # Make sure we're on the develop branch
    current_branch=$(git symbolic-ref --short HEAD)
    if [[ "$current_branch" != "develop" ]]; then
        echo "Switching to develop branch..."
        git checkout develop
        echo "done"
    fi

    # Pull the latest changes
    git pull

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to running \"git pull\"" >> /dev/stderr
        exit 1
    fi

    # Get latest release version starting from v1.0.0
    echo "Checking latest release version..."
    latest_version=$(curl -s "https://api.github.com/repos/Wil3on/gameap/releases" | jq -r '[.[] | select(.tag_name >= "v1.0.0")] | sort_by(.published_at) | reverse[0].tag_name')
    
    if [[ -n "$latest_version" && "$latest_version" != "null" ]]; then
        echo "Found latest release: $latest_version"
        # Checkout the specific tag/release
        git checkout $latest_version
        if [[ "$?" -ne "0" ]]; then
            echo "Unable to checkout release $latest_version" >> /dev/stderr
            echo "Continuing with latest develop branch commit" >> /dev/stderr
        fi
    else
        echo "No releases found starting from v1.0.0, using latest develop branch commit"
    fi

    echo
    echo "Updating Composer packages..."
    echo "This may take a long while..."
    composer update --no-dev --optimize-autoloader &> /dev/null

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to update Composer packages. " >> /dev/stderr
        exit 1
    fi
    echo "done"

    echo
    echo "Building the styles..."
    # Check if 'prod' script exists in package.json, if not use 'build' instead
    if grep -q '"prod":' package.json; then
        npm run prod &> /dev/null
    else
        # Newer projects might use 'build' instead of 'prod'
        npm run build &> /dev/null
    fi
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to build styles. " >> /dev/stderr
        echo "Styles building aborted." >> /dev/stderr
        exit 1
    fi
    echo "done"

    upgrade_migrate
    upgrade_postscripts
}

upgrade_from_official_repo ()
{
    cd $gameap_path || exit 1

    download_unpack_from_repo
    upgrade_migrate
    upgrade_postscripts
}


cron_setup ()
{
    crontab -l > gameap_cron
    echo "* * * * * cd ${gameap_path} && php artisan schedule:run >> /dev/null 2>&1" >> gameap_cron
    crontab gameap_cron
    rm gameap_cron
}

_check_systemd()
{
    if ! command -v systemctl > /dev/null 2>&1; then
        return 1
    fi

    if ! systemctl daemon-reload >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

_service_start ()
{
    local service_name=$1

    if _check_systemd; then
        if ! systemctl start $service_name; then
            return 1
        fi
    else
        if ! service $service_name start; then
            return 1
        fi
    fi

    return 0
}

_service_restart ()
{
    local service_name=$1

    if _check_systemd; then
        if ! systemctl restart $service_name; then
            return 1
        fi
    else
        if ! service $service_name restart; then
            return 1
        fi
    fi

    return 0
}

mysql_service_start ()
{
    echo "Unfortunately, your architecture are not supported by this script."
    exit 2
}

_detect_os
_detect_arch

gameapctl_version="0.6.0"
gameapctl_url="https://github.com/gameap/gameapctl/releases/download/v${gameapctl_version}/gameapctl-v${gameapctl_version}-linux-${cpuarch}.tar.gz"

echo "Preparation for installation..."
_curl_check
_tar_check

if ! command -v gameapctl > /dev/null; then
  echo
  echo
  echo "Downloading gameapctl for your operating system..."
  curl -sL ${gameapctl_url} --output /tmp/gameapctl-v${gameapctl_version}-linux-${cpuarch}.tar.gz &> /dev/null

  echo
  echo
  echo "Unpacking archive..."
  tar -xvf /tmp/gameapctl-v${gameapctl_version}-linux-${cpuarch}.tar.gz -C /usr/local/bin

  chmod +x /usr/local/bin/gameapctl
fi

if ! command -v gameapctl > /dev/null; then
  PATH=$PATH:/usr/local/bin
fi

echo
echo
echo "gameapctl updating..."
gameapctl self-update

echo
echo
echo "Running installation..."
bash -c "gameapctl panel install $*"
