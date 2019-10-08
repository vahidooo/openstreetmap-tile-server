#!/bin/bash

set -x

function createPostgresConfig() {
  cp /etc/postgresql/10/main/postgresql.custom.conf.tmpl /etc/postgresql/10/main/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/10/main/postgresql.custom.conf
  cat /etc/postgresql/10/main/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

if [ "$1" = "import" ]; then
    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderer
    sudo -u postgres createdb -E UTF8 -O renderer gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

    args=("$@")
    ELEMENTS=${#args[@]}
    for (( i=1;i<$ELEMENTS;i++)); do
        if [ ! -f "/planet/${args[${i}]}-latest.osm.pbf" ]; then
            echo "LOG: preparing to download ${args[${i}]} ..."
		file="/planet/${args[${i}]}.osm.pbf"
		mkdir -p "${file%/*}" && touch "$file"
            echo "LOG: downloading ${args[${i}]} ..."
            wget -nv "http://download.geofabrik.de/${args[${i}]}-latest.osm.pbf" -O "/planet/${args[${i}]}-latest.osm.pbf"
         fi
     done

    echo "LOG: merging all countries osm files and building corresponding poly file"
    osmium merge /planet/*/*.osm.pbf  -o /planet/planet.osm.pbf
    osmosis --read-xml file="/planet/planet-latest.osm" --bounding-polygon file="/planet/planet.poly"
#        wget -nv http://download.geofabrik.de/europe/luxembourg.poly -O /data.poly

    # determine and set osmosis_replication_timestamp (for consecutive updates)
    osmium fileinfo /planet/planet.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
    osmium fileinfo /planet/planet.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
    REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

    # initial setup of osmosis workspace (for consecutive updates)
    sudo -u renderer openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP

    # copy polygon file if available
    if [ -f /planet/planet.poly ]; then
        sudo -u renderer cp /planet/planet.poly /var/lib/mod_tile/planet/planet.poly
    fi

    # Import data
    echo "********************* importing data ... *********************"
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} ${OSM2PGSQL_EXTRA_ARGS} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /planet/planet.osm.pbf

    # Create indexes
    sudo -u postgres psql -d gis -f indexes.sql

    service postgresql stop

    exit 0
fi

if [ "$1" = "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # Fix postgres data privileges
    chown postgres:postgres /var/lib/postgresql -R

    # Configure Apache CORS
    if [ "$ALLOW_CORS" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "$UPDATES" = "enabled" ]; then
      /etc/init.d/cron start
    fi

    # Run
    sudo -u renderer renderd -f -c /usr/local/etc/renderd.conf
    service postgresql stop

    exit 0
fi
if [ "$1" = "clean-tiles" ]; then
rm -r /var/lib/mod_tile/ajt/*
 exit 0
fi
if [ "$1" = "append" ]; then
     echo "LOG: downloading $2 ..."
     wget -nv "http://download.geofabrik.de/$2-latest.osm.pbf" -O "/planet/$2-latest.osm.pbf"
     echo "LOG: appending $2 ..."
     sudo -u renderer osm2pgsql -d gis --append --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} ${OSM2PGSQL_EXTRA_ARGS} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /planet/$2-latest.osm.pbf
 exit 0
fi



echo "invalid command"
exit 1
