#!/bin/bash
# THE MUST-NOT-MATCH TEST FOR THE dpkg STATUS FILTER, and it exists because the obvious
# version of queries/packages-linux.sql was wrong.
#
# dpkg keeps a record of a package that was REMOVED BUT NOT PURGED -- state `rc`, status
# `deinstall ok config-files` -- and osquery reports it WITH THE VERSION STILL ATTACHED.
# Without `WHERE status LIKE '%ok installed'` an agent someone uninstalled reads as an
# installed one: a wrong answer wearing a right one's face.
#
# THE PACKAGE CHOICE IS THE TEST. A first attempt used `cowsay` and proved nothing: it
# carries no conffiles, so dpkg drops the record entirely on remove and the unfiltered
# query looked correct. `nano` ships /etc/nanorc and `cron` ships /etc/crontab, so both
# leave a config-files record behind. Do not "simplify" this to a smaller package without
# checking it has conffiles.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
[ "$(pm)" = apt ] || { echo "SKIP: dpkg states need an apt distro"; exit 3; }

try "installing nano and cron, which ship conffiles" need_pkgs nano cron \
  || echo "WARN: the packages this scenario removes did not install"
echo "--- installed:"; dpkg -l nano cron 2>/dev/null | tail -2

# REMOVE, NOT PURGE. --purge would delete the record and the scenario would pass for the
# wrong reason.
try "apt-get remove (NOT purge) of nano and cron" \
  sudo_maybe apt-get -qq remove -y nano cron \
  || echo "WARN: the removal this scenario tests did not happen"
echo "--- after remove (expect rc, not ii):"; dpkg -l nano cron 2>/dev/null | tail -2
