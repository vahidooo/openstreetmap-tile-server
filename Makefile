.PHONY: build push test

build:
	docker build -t my/osm-tile-server_base -f Dockerfile_base .
	docker build -t my/osm-tile-server -f Dockerfile_cont .

push: build
	docker push overv/openstreetmap-tile-server:latest

test: build
	docker volume create openstreetmap-data
	docker run -v openstreetmap-data:/var/lib/postgresql/10/main overv/openstreetmap-tile-server import
	docker run -v openstreetmap-data:/var/lib/postgresql/10/main -p 80:80 -d overv/openstreetmap-tile-server run