#!/bin/bash

BASEDIR=`dirname "$0"`
DIFF=`which diff`
PRINTF=`which printf`

cd "$BASEDIR"

if [ ! -x "$DIFF" ]
then
    echo "Cannot find the diff command. Exiting."
    exit 1
fi

if [ ! -x "$PRINTF" ]
then
  echo "Cuould not find the printf command. Falling back on echo -- expect ugly output."
  PRINTF="echo"
fi

if [ -x "$BASEDIR/../andromeda" ]
then
  ANDROMEDA="$BASEDIR/../andromeda"
elif [ -x "$BASEDIR/../andromeda.native" ]
then
  ANDROMEDA="$BASEDIR/../andromeda.native"
elif [ -x "$BASEDIR/../andromeda.byte" ]
then
  ANDROMEDA="$BASEDIR/../andromeda.byte"
else
  echo "Cannot find the Andromeda executable. Compile Andromeda first."
  exit 1
fi

VALIDATE=0
if [ "$1" = "-v" ]
then
    VALIDATE=1
fi
for FILE in $BASEDIR/*.m31
  do
  "$ANDROMEDA" "$FILE" >"$FILE.out" 2>&1
  if [ -f $FILE.ref ]
      then
      RESULT=`"$DIFF" "$FILE.ref" "$FILE.out"`
      if [ "$?" = "0" ]
      then
      $PRINTF "Test: $FILE                        \r"
      rm "$FILE.out"
      else
      echo "FAILED:  $FILE                          "
      if [ $VALIDATE = "1" ]
          then
          # Is it about whitespace?
          "$DIFF" --ignore-blank-lines --ignore-all-space "$FILE.ref" "$FILE.out" 2>/dev/null 1>/dev/null
          if [ "$?" = "0" ]
          then
              ONLYWHITE="\n[Note: only white space changed]"
          else
              ONLYWHITE=""
          fi
          "$DIFF" --unified "$FILE.ref" "$FILE.out"
          echo "$ONLYWHITE"
          read -p "Validate $FILE.out as new $FILE.ref? (y/n/q) [n] " ans
          if [ "$ans" = "y" -o "$ans" = "Y" ]
          then
          mv "$FILE.out" "$FILE.ref"
          echo "Validated: $FILE"
          elif [ "$ans" = "q" -o "$ans" = "Q" ]
          then
          exit 0
          fi
      fi
      fi

  else
      mv "$FILE.out" "$FILE.ref"
      echo "Created: $FILE.ref                        "
  fi
done
echo "Done.                                       "
