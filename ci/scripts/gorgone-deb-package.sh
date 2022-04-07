#!/bin/sh
set -ex

if [ -z "$VERSION" -o -z "$RELEASE" -o -z "$DISTRIB" ] ; then
  echo "You need to specify VERSION / RELEASE / DISTRIB variables"
  exit 1
fi

echo "################################################## PACKAGING COLLECT ##################################################"

AUTHOR="Luiz Costa"
AUTHOR_EMAIL="me@luizgustavo.pro.br"
REVISION=bullseye
if [ -d ./tmp ] ; then
  rm -rf ./tmp
fi

mkdir -p ./tmp
cd ./tmp
apt-cache dumpavail | dpkg --merge-avail

yes | dh-make-perl make --build --version "0.11.3-${RELEASE}" --cpan Mojolicious::Plugin::BasicAuthPlus
dpkg -i libmojolicious-plugin-basicauthplus-perl_0.11.3-${RELEASE}_all.deb

yes | dh-make-perl make --build --revision ${RELEASE} --cpan ZMQ::Constants
dpkg -i libzmq-constants-perl_1.04-${RELEASE}_all.deb

git clone https://github.com/centreon-lab/zmq-libzmq4-perl.git zmq-libzmq4-perl-0.02
mkdir zmq-libzmq4-perl
mv -v zmq-libzmq4-perl-0.02 zmq-libzmq4-perl/
cd zmq-libzmq4-perl/
tar czpvf zmq-libzmq4-perl-0.02.tar.gz zmq-libzmq4-perl-0.02
cd zmq-libzmq4-perl-0.02
rm -rf debian/changelog
debmake -f "${AUTHOR}" -e "${AUTHOR_EMAIL}" -b ":perl" -r $RELEASE -y
debuild-pbuilder -uc -us
cd ..
dpkg -i zmq-libzmq4-perl_0.02-${RELEASE}_all.deb
cd ../../

if [ -d centreon-gorgone/build ] ; then
    rm -rf centreon-gorgone/build
fi
ls -lart
tar czpf centreon-gorgone-$VERSION.tar.gz src/centreon-gorgone
mv centreon-gorgone-$VERSION.tar.gz src/centreon-gorgone
cd src/centreon-gorgone/
ls -lart
cp -rf ci/debian .
debmake -f "${AUTHOR}" -e "${AUTHOR_EMAIL}" -u "$VERSION" -b ":perl" -y -r "$RELEASE"
debuild-pbuilder
cd ../

if [ -d "$DISTRIB" ] ; then
  rm -rf "$DISTRIB"
fi
mkdir $DISTRIB
mv tmp/libmojolicious-plugin-basicauthplus-perl_0.11.3-${RELEASE}_all.deb $DISTRIB/
mv tmp/zmq-libzmq4-perl_0.02-${RELEASE}_all.deb $DISTRIB/
mv tmp/libzmq-constants-perl_1.04-${RELEASE}_all.deb $DISTRIB/
mv *.deb $DISTRIB/
mv $DISTRIB/*.deb /src
