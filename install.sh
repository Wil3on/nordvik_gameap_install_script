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
    if ! _service_start mysql; then
        if ! _service_start mariadb; then
            echo "Failed to start mysql/mariadb" >> /dev/stderr
            exit 1
        fi
    fi
}

mysql_service_restart ()
{
    if ! _service_restart mysql; then
        if ! _service_restart mariadb; then
            echo "Failed to restart mysql/mariadb" >> /dev/stderr
            exit 1
        fi
    fi
}

mysql_setup ()
{
    if command -v mysqld > /dev/null; then
        mysql_manual=1

        echo
        echo "Detected installed mysql..."

        echo "MySQL configuring skipped."
        echo "Please configure MySQL manually."

        ask_mysql_credentials

        until mysql -h ${database_hostname} -u ${database_user_name} -p${database_user_password} -e ";" ; do
            echo
            echo "Can't connect to MySQL. Invalid credentials. Please retry"

            ask_mysql_credentials
        done
    else
        mysql_manual=0

        database_root_password=$(generate_password)
        database_user_name="gameap"
        database_user_password=$(generate_password)
        database_name="gameap"

        echo debconf mysql-server/root_password password $database_root_password | debconf-set-selections
        echo debconf mysql-server/root_password_again password $database_root_password | debconf-set-selections

        install_packages "$(get_package_name mysql)"
        unset mysql_package

        mysql_service_start

        mysql -u root -p${database_root_password} -e 'CREATE DATABASE IF NOT EXISTS `gameap`' &> /dev/null

        mysql -u root -p${database_root_password} -e "USE mysql;\
            CREATE USER '${database_user_name}'@'%' IDENTIFIED BY '${database_user_password}';\
            GRANT SELECT ON *.* TO '${database_user_name}'@'%';\
            GRANT ALL PRIVILEGES ON gameap.* TO '${database_user_name}'@'%';
            FLUSH PRIVILEGES;"

        if [[ "$?" -ne "0" ]]; then echo "Unable to grant privileges. MySQL seting up failed." >> /dev/stderr; exit 1; fi
    fi
}

nginx_setup ()
{
    if command -v nginx > /dev/null; then
        echo "Detected installed nginx..."
    else
        add_gpg_key "https://nginx.org/keys/nginx_signing.key"

        if [[ "${os}" = "debian" ]]; then
            echo "deb http://nginx.org/packages/debian/ ${dist} nginx" | tee /etc/apt/sources.list.d/nginx.list
        elif [[ "${os}" = "ubuntu" ]]; then

            if [[ "${dist}" != "focal" ]]; then
                echo "deb http://nginx.org/packages/ubuntu/ ${dist} nginx" | tee /etc/apt/sources.list.d/nginx.list
            fi
        fi

        update_packages_list
        install_packages nginx
    fi

    if [[ "${dist}" != "focal" ]]; then
        nginx_gameap_conf_path="/etc/nginx/conf.d/${gameap_server_name}.conf"
    else
        nginx_gameap_conf_path="/etc/nginx/sites-enabled/${gameap_server_name}.conf"
    fi

    curl -SfL https://raw.githubusercontent.com/gameap/auto-install-scripts/master/web-server-configs/nginx-no-ssl.conf \
        --output "${nginx_gameap_conf_path}" &> /dev/null
    
    if [[ "$?" -ne "0" ]]; then
        echo "Unable to download default nginx config" >> /dev/stderr
        echo "Nginx configuring skipped" >> /dev/stderr
        return
    fi

    sed -i "s/^\(\s*user\s*\).*$/\1www-data\;/" /etc/nginx/nginx.conf

    gameap_public_path="$gameap_path/public"

    if is_ipv4 "${gameap_host}"; then
        sed -i "s/^\(\s*listen\s*\).*$/\1${gameap_host}\:${gameap_port}\;/" ${nginx_gameap_conf_path}
    else
        sed -i "s/^\(\s*server\_name\s*\).*$/\1${gameap_host}\;/" ${nginx_gameap_conf_path}
        sed -i "s/^\(\s*listen\s*\).*$/\180\;/" ${nginx_gameap_conf_path}
        sed -i "s/listen 80\;/listen ${gameap_port}\;/" ${nginx_gameap_conf_path}
    fi;

    sed -i "s/^\(\s*root\s*\).*$/\1${gameap_public_path//\//\\/}\;/" ${nginx_gameap_conf_path}
    sed -i "s/^\(\s*root\s*\).*$/\1${gameap_public_path//\//\\/}\;/" ${nginx_gameap_conf_path}

    fastcgi_pass=unix:/var/run/php/php${php_version}-fpm.sock
    sed -i "s/^\(\s*fastcgi_pass\s*\).*$/\1${fastcgi_pass//\//\\/}\;/" ${nginx_gameap_conf_path}

    _service_start nginx
    _service_start php${php_version}-fpm
}

apache_setup ()
{
    if command -v apache2 > /dev/null; then
        echo "Detected installed apache..."
    else
        install_packages apache2 libapache2-mod-php${php_version}
    fi

    curl -SfL https://raw.githubusercontent.com/gameap/auto-install-scripts/master/web-server-configs/apache-no-ssl.conf \
        --output /etc/apache2/sites-available/${gameap_server_name}.conf &> /dev/null

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to download default Apache config" >> /dev/stderr
        echo "Apache configuring skipped" >> /dev/stderr
        return
    fi

    ln -s /etc/apache2/sites-available/${gameap_server_name}.conf /etc/apache2/sites-enabled/${gameap_server_name}.conf

    gameap_public_path="$gameap_path/public"
    gameap_ip=$(getent hosts ${gameap_host} | awk '{ print $1 }')

    sed -i "s/^\(\s*<VirtualHost\s*\).*\(:[0-9]*>\)$/\1${gameap_ip}\:${gameap_port}>/" /etc/apache2/sites-available/${gameap_server_name}.conf
    sed -i "s/^\(\s*ServerName\s*\).*$/\1${gameap_host}/" /etc/apache2/sites-available/${gameap_server_name}.conf
    sed -i "s/^\(\s*DocumentRoot\s*\).*$/\1${gameap_public_path//\//\\/}/" /etc/apache2/sites-available/${gameap_server_name}.conf
    sed -i "s/^\(\s*[\<{1}]Directory\s*\).*$/\1${gameap_public_path//\//\\/}>/" /etc/apache2/sites-available/${gameap_server_name}.conf

    # Enable listening on the custom port if it's not 80
    if [[ "${gameap_port}" != "80" ]]; then
        echo "Listen ${gameap_port}" >> /etc/apache2/ports.conf
    fi

    a2enmod rewrite
    _service_start apache2
}

ask_user ()
{
    if [[ -z "${gameap_path}" ]]; then
        while true; do
            echo 
            read -p "Enter gameap installation path (Example: /var/www/gameap): " gameap_path

            if [[ -z "${gameap_path}" ]]; then
                gameap_path="/var/www/gameap"
            fi
            
            if [[ ! -s "${gameap_path}" ]]; then
                    read -p "${gameap_path} not found. Do you wish to make directory? (Y/n): " yn
                    case $yn in
                        [Yy]* ) mkdir -p ${gameap_path}; break;;
                    esac
            else 
                break;
            fi
        done
    fi

    if [[ -z "${upgrade:-}" ]]; then

        while [ -z "${gameap_host}" ]; do
            read -p "Enter gameap host (example.com): " gameap_host
        done

        gameap_port="80"
        read -p "Enter gameap panel port [80]: " input_port
        if [[ ! -z "${input_port}" ]]; then
            gameap_port="${input_port}"
        fi

        gameap_server_name="gameap"
        read -p "Enter gameap Server Name [gameap]: " input_server_name
        if [[ ! -z "${input_server_name}" ]]; then
            gameap_server_name="${input_server_name}"
        fi

        if [[ -z "${db_selected:-}" ]]; then
            echo
            echo "Select database to install and configure"

            echo "1) MySQL"
            echo "2) SQLite"
            echo "3) None. Do not install a database"
            echo 

            while true; do
                read -p "Enter number: " db_selected
                case $db_selected in
                    1* ) db_selected="mysql"; echo "Okay! Will try install MySQL..."; break;;
                    2* ) db_selected="sqlite"; echo "Okay! Will try install SQLite..."; break;;
                    3* ) db_selected="none"; echo "Okay! ..."; break;;
                    * ) echo "Please answer 1-3.";;
                esac
            done
        fi

        if [[ -z "${web_selected:-}" ]]; then
            echo
            echo "Select Web-server to install and configure"

            echo "1) Nginx (Recommended)"
            echo "2) Apache"
            echo "3) None. Do not install a Web Server"
            echo 

            while true; do
                read -p "Enter number: " web_selected
                case $web_selected in
                    1* ) web_selected="nginx"; echo "Okay! Will try to install Nginx..."; break;;
                    2* ) web_selected="apache"; echo "Okay! Will try install Apache..."; break;;
                    3* ) web_selected="none"; echo "Okay! ..."; break;;
                    * ) echo "Please answer 1-3.";;
                esac
            done
        fi

    fi
}

ask_mysql_credentials ()
{
    read -p "Enter DB host: " database_hostname
    read -p "Enter DB username: " database_user_name
    read -p "Enter DB password: " database_user_password
    read -p "Enter DB name: " database_name
}

main ()
{
    detect_os

    ask_user

    update_packages_list

    curl_check
    gpg_check

    if ! _detect_source_repository; then
        echo "Unable to detect source repository" >> /dev/stderr
        exit 1
    fi

    from_github=1

    if [[ -n "${upgrade:-}" ]]; then
        if [[ -n "${from_github:-}" ]]; then
            upgrade_from_github
        else
            upgrade_from_official_repo
        fi

        exit 0
    fi

    install_packages software-properties-common apt-transport-https

    php_packages_check

    if [[ -z "${php_version}" ]]; then
        echo "Unable to find PHP >= 7.3" >> /dev/stderr
        echo "For Ubuntu 24.04, you may need to manually add the PHP repository:" >> /dev/stderr
        echo "  sudo add-apt-repository -y ppa:ondrej/php" >> /dev/stderr
        echo "  sudo apt-get update" >> /dev/stderr
        echo "  sudo apt-get install -y php8.3" >> /dev/stderr
        echo "Then try running this script again." >> /dev/stderr
        exit 1
    fi

    install_packages php${php_version}-common \
        php${php_version}-gd \
        php${php_version}-cli \
        php${php_version}-fpm \
        php${php_version}-mysql \
        php${php_version}-pgsql \
        php${php_version}-curl \
        php${php_version}-bz2 \
        php${php_version}-zip \
        php${php_version}-xml \
        php${php_version}-mbstring \
        php${php_version}-bcmath \
        php${php_version}-gmp \
        php${php_version}-intl
    
    install_from_github

    case $db_selected in
        "mysql" )
            mysql_setup

            sed -i "s/^\(DB\_CONNECTION\s*=\s*\).*$/\1mysql/" .env
            sed -i "s/^\(DB\_DATABASE\s*=\s*\).*$/\1${database_name}/" .env
            sed -i "s/^\(DB\_USERNAME\s*=\s*\).*$/\1${database_user_name}/" .env
            sed -i "s/^\(DB\_PASSWORD\s*=\s*\).*$/\1${database_user_password}/" .env
        ;;

        "sqlite" ) 
            install_packages php${php_version}-sqlite
            database_name="${gameap_path}/database.sqlite"
            touch $database_name

            sed -i "s/^\(DB\_CONNECTION\s*=\s*\).*$/\1sqlite/" .env
            sed -i "s/^\(DB\_DATABASE\s*=\s*\).*$/\1${database_name//\//\\/}/" .env
        ;;
    esac

    generate_encription_key

    if [[ "${db_selected}" != "none" ]]; then
        echo "Migrating database..."

        if [[ ${mysql_manual:-0} == 1 ]]; then
            php artisan migrate
        else
            php artisan migrate --seed
        fi

        if [[ "$?" -ne "0" ]]; then
            echo "Unable to migrate database." >> /dev/stderr
            echo "Database seting up aborted." >> /dev/stderr
            exit 1
        fi
        echo "done"
    fi

    if [[ "${web_selected}" != "none" ]]; then
        case $web_selected in
            "nginx" ) nginx_setup;;
            "apache" ) apache_setup;;
        esac
    fi

    chown -R www-data:www-data ${gameap_path}
    cron_setup

    # Change admin password
    cd $gameap_path
    admin_password=$(generate_password)
    php artisan user:change-password "admin" "${admin_password}"

    echo
    echo
    echo
    echo "---------------------------------"
    echo "DONE!"
    echo
    echo "GameAP file path: ${gameap_path}"
    echo

    if [[ "${db_selected}" = "sqlite" ]]; then
        echo "Database: ${database_name}"
    else
        if [[ ! -z "$database_root_password" ]]; then echo "Database root password: ${database_root_password}"; fi
        echo "Database name: gameap"
        if [[ ! -z "$database_user_name" ]]; then echo "Database user name: ${database_user_name}"; fi
        if [[ ! -z "$database_user_password" ]]; then echo "Database user password: ${database_user_password}"; fi
    fi

    echo
    echo "Administrator credentials"
    echo "Login: napster or via email nertsent@gmail.com"
    echo "Password: fpwPOuZD"
    echo
    echo "Host: http://${gameap_host}:${gameap_port}"
    echo
    echo "---------------------------------"
}

parse_options "$@"
main