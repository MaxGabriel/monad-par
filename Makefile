
# This provides some convenient shorthands for installing many cabal packages.

# It is essentially a more compact way of bundling what would be a
# handful of shell scripts.

# --------------------------------------------------------------------------------

OUR_PKGS= abstract-par/ monad-par-extras/ monad-par/ meta-par/  \
  RPC/ meta-par-dist-tcp/                                       \
  meta-par-cuda/ abstract-par-accelerate/ meta-par-accelerate/

DEQUE_PKGS= Deques/CAS/ Deques/AbstractDeque/ Deques/MichaelScott/ Deques/ChaseLev/ Deques/MegaDeque/ 

ACC_PKGS= accelerate/ accelerate/accelerate-io/ accelerate/accelerate-cuda/ 

ALL_PKGS= ${DEQUE_PKGS} ${ACC_PKGS} ${OUR_PKGS}

# if [ "$HADDOCK" == "" ];
# then HADDOCK=`which haddock`
# fi
# if [ "$CABAL" == "" ];
# then CABAL=`which cabal`
# fi
# if [ "$GHC" == "" ];
# then GHC=`which ghc`
# fi

ifeq ($(GHC),)
  GHC=`which ghc`
endif 

HADDOCK= "$(HOME)/.cabal/bin/haddock"
CABAL= cabal

CABAL_INSTALL= ${CABAL} install --with-ghc=${GHC} --with-haddock=${HADDOCK}

# --------------------------------------------------------------------------------

install: install-with-tests

install-with-tests:
	${CABAL_INSTALL} ${OUR_PKGS} --enable-tests

install-all:
	${CABAL_INSTALL} ${OUR_PKGS}


mega-install:
	${CABAL_INSTALL} ${ALL_PKGS}

doc:
	rm -rf docs
	mkdir docs
        # Link EVERYTHING to Haddock:
	${CABAL_INSTALL} ${ALL_PKGS} --enable-documentation --haddock-html-location='http://hackage.haskell.org/packages/archive/$pkg/latest/doc/html' 
	mv */dist/doc/html/* docs/
	mv ./Deques/*/dist/doc/html/* docs/
	mv ./accelerate/*/dist/doc/html/* docs/

# TODO: If we also moved over all the otherd docs from the global and
# user DBs we could create a complete documentation collection on this
# website and no longer depend on hackage:
install-doc:
	rsync -vrplt docs/ ~/.hyplan/haddock/
	cd ~/.hyplan/haddock/
	makedirindex > index.html
	chmod ugo+rX -R .

clean:
