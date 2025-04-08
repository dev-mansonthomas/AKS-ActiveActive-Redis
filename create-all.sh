#!/bin/bash

./01-create-cluster.sh
./02-setup-haproxy.sh
./03-setup-rerc.sh
./04-create-active-active-db.sh