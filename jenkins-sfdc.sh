#!/bin/bash
# Single script for jenkins builds.

# Quiet down pushd, popd.
pushd() {
	command pushd "$@" > /dev/null
}

popd() {
	command popd "$@" > /dev/null
}

#Variables that are aware of the Jenkins workspace and Salesforce packaging
buildenv=`echo $JOB_NAME`
sandbox="dist/Salesforce"


# Compare branch with develop and make a change set for the comparison
echo "Comparing $GIT_BRANCH and origin/develop for change set"
[ -z "$git_diff" ] && git_diff="git diff -w --name-only origin/develop"

#echo "Creating Salesforce Sandbox for deployment."
# [ ! -d "$sandbox/src" ] && mkdir -p "$sandbox/src"

# Salesforce ant files -- TODO: Construct package.xml
antfiles="src/package.xml"
propfile="../builds/build.properties_template"
buildXML="$sandbox/build.xml"
[ -f "../builds/build.properties" ] && rm ../builds/build.properties

# Component types that we deploy
types="	approvalProcess  \
	assignmentRules \
	autoResponseRules \
	cls \
  	cmp \
	component \
	connectedApps \
  	css \
	customPermission \
	email \
  	evt \
	flow \
	flowDefinition \
	globalValueSet \
	group \
  	js \
	labels \
	layout \
	liveChatButton \
	md \
	mdt \
	object \
	page \
	queue \
	quickAction \
	reportType \
	resource \
	role \
	settings \
	sharingRules \
  	standardValueSets \
	synonymDictionary \
	tab \
	trigger \
  	workflow"

typemeta="	cls\
    		cmp\
		component\
		email\
    		evt\
		page\
		resource\
		trigger"

# For creating the deployment change set
gitfiles=$sandbox/gitchanges
profiles=$sandbox/profiles

# currently only used to make run tests
classfiles=$sandbox/classfiles

# blacklist is mostly for files that should be a custom setting but haven't completed that task
# as well as files that sometimes we can't deploy
blacklist=build/blacklist
whitelist=build/whitelist
destructiveChanges=./build/`ls build | grep destructiveChanges`
skipUnitTests=build/skipUnitTests
runUnitTests=build/runUnitTests


# Create the package
function makePackage() {
   for antfile in $antfiles; do
	   echo "Copying $antfile"
	   [ -f $antfile ] && cp $antfile $sandbox/src
   done


   [ -f "$destructiveChanges" ] && echo "Copying $destructiveChanges" && cp $destructiveChanges $sandbox/src

   while read srcfile; do
	type=`echo "$srcfile" | rev | cut -f 1 -d '.' | rev`
	dofile=`echo $types | grep $type`
        dometa=`echo $typemeta | grep $type`
	blacklisted=`cat "$blacklist" | grep "$srcfile"`
        if [ ! -z "$dofile" ] && [ -z "$blacklisted" ] ; then
		isSrc=`echo $srcfile | grep src`
		isAura=`echo $srcfile | grep aura`
		if [ -f "$srcfile" ] && [ ! -z "$isSrc" ] && [ ! -z "$isAura" ] ; then
			auraPackage="src/aura/`echo $srcfile | cut -f 3 -d '/'`"
			[ -d "$auraPackage" ] && cp -rp --parents $auraPackage/* $sandbox
		else
                	[ -f "$srcfile" ] && [ ! -z "$isSrc" ] && cp -rp --parents "$srcfile" $sandbox
                	if [ ! -z "$dometa"  ]; then
                        	[ -f "${srcfile}-meta.xml" ] && cp -rp --parents "${srcfile}-meta.xml" $sandbox
                	fi
		fi
        fi
  done < $gitfiles

# Compress package  

  pushd $sandbox/src
  zip -r ../$archive *
  popd
}

function sumPackage() {
   zMD5SUM=`md5sum "$sandbox/$archive"`
   echo $zMD5SUM
}

# if flow has been deployed then unpackzip and remove flows and so we can use deployRoot
function checkFlows() {
   currentenv=`cat $propfile | grep username | cut -f 4 -d .`
   soda pull $currentenv

   SFDCFlows=`zipinfo -1 "$sandbox/$archive" | grep '.\.flow$'`
   for SFDCFlow in $SFDCFlows; do
      [ -f "$sodaenv/$currentenv/$SFDCFlow" ] && blockflow=true && rm $sandbox/src/$SFDCFlow
   done
}

function makeBuildXML() {

   runLocalTestsRootDir="     <sf:deploy username=\"\${sf.username}\" password=\"\${sf.password}\" serverurl=\"\${sf.serverurl}\" maxPoll=\"\${sf.maxPoll}\" deployRoot=\"./src\" checkOnly=\"\${sf.checkonly}\" testLevel=\"RunLocalTests\" ignoreWarnings=\"true\">"
   runLocalTestsZipFile="     <sf:deploy username=\"\${sf.username}\" password=\"\${sf.password}\" serverurl=\"\${sf.serverurl}\" maxPoll=\"\${sf.maxPoll}\" zipFile=\"$archive\" checkOnly=\"\${sf.checkonly}\" testLevel=\"RunLocalTests\" ignoreWarnings=\"true\">"
   runSpecifiedTestsRootDir="     <sf:deploy username=\"\${sf.username}\" password=\"\${sf.password}\" serverurl=\"\${sf.serverurl}\" maxPoll=\"\${sf.maxPoll}\" deployRoot=\"./src\" checkOnly=\"\${sf.checkonly}\" testLevel=\"RunSpecifiedTests\" ignoreWarnings=\"true\">"
   runSpecifiedTestsZipFile="     <sf:deploy username=\"\${sf.username}\" password=\"\${sf.password}\" serverurl=\"\${sf.serverurl}\" maxPoll=\"\${sf.maxPoll}\" zipFile=\"$archive\" checkOnly=\"\${sf.checkonly}\" testLevel=\"RunSpecifiedTests\" ignoreWarnings=\"true\">"

   SFDCClasses=`zipinfo -1 "$sandbox/$archive" | grep '.cls$'`
   echo '<project name="Salesforce Ant tasks" default="sfdcDeploy" basedir="." xmlns:sf="antlib:com.salesforce">' > "$buildXML"
   echo '     <property file="build.properties"/>' >> "$buildXML"
   echo '     <property environment="sandbox"/>' >> "$buildXML"
   echo '   <target name="sfdcDeploy">' >> "$buildXML"
   if [ "$testLevel" == "RunLocalTests" ]; then
      if [ "$blockflow" == "true" ]; then
         echo "$runLocalTestsRootDir" >> "$buildXML"
      else
	 echo "$runLocalTestsZipFile" >> "$buildXML"
      fi
   elif [ "$testLevel" == "RunSpecifiedTests" ]; then
      if [ ! -z "$SFDCClasses" ]; then
	 if [ "$blockflow" == "true" ]; then
            echo "$runSpecifiedTestsRootDir" >> "$buildXML"
	 else
	    echo "$runSpecifiedTestsZipFile" >> "$buildXML"
	 fi
         for SFDCClass in $SFDCClasses; do
	     testCLS=`echo $SFDCClass | grep -i Test`
	     metaFile=`echo $SFDCClass | grep meta`
	     skipTest=`cat $skipUnitTests | grep "$SFDCClass"`
	     echo $SFDCClass
	     if [ -z "$testCLS" ] && [ -z "$metaFile" ] && [  -z "$skipTest" ]; then
		 cls=`echo $SFDCClass | cut -f 2 -d '/' | cut -f 1 -d '.'`
		 [ -f "src/classes/${cls}_Test.cls" ] && echo "         <runTest>${cls}_Test</runTest>" >> "$buildXML"
	     fi
         done
         if [ -f "$runUnitTests" ]; then
             echo "end" >> $runUnitTests
             while read utest; do
                [ "$utest" != "end" ] && echo "         <runTest>$utest</runTest>" >> "$buildXML"
             done < $runUnitTests
         fi
      else
	 if [ "$blockflow" == "true" ]; then
	    echo "$runAllTestsRootDir" >> "$buildXML"
	 else
	    echo "$runAllTestsZipFile" >> "$buildXML"
	 fi
      fi
   else
      if [ "$blockflow" == "true" ]; then
	 echo "$runAllTestsRootDir" >> "$buildXML"
      else
	 echo "$runAllTestsZipFile" >> "$buildXML"
      fi
   fi
   echo '      </sf:deploy>' >> "$buildXML"

   echo '   </target>' >> "$buildXML"
   echo '</project>' >> "$buildXML"
}

isprod=`echo $buildenv | grep _prod`
echo $isprod
if [ ! -z "$isprod" ]; then
# Creating string for archive name
   archive=`ls dist/Salesforce/* | rev | cut -f 1 -d '/' |rev`
   archive_num=`echo $archive | cut -f 2 -d '-' | cut -f 1 -d '.'`
#   getPackage
   git diff --no-ext-diff --unified=0 --exit-code -a --no-prefix origin/release/DEPLOYMENT-$archive_num build/runUnitTests | egrep "^\-" | cut -d '-' -f 2 >> $runUnitTests
   echo "end" >> $runUnitTests
else
   #Clean Sandbox
   rm -rf $sandbox/*
   [ ! -d "$sandbox/src" ] && mkdir -p "$sandbox/src"
   $git_diff $GIT_BRANCH > $gitfiles
   cat $whitelist >> $gitfiles
# Creating string for archive name
   archive="Salesforce-`echo $GIT_BRANCH | cut -f 3 -d '/' | cut -f 2 -d '-'`.zip"
   makePackage
   checkFlows
fi

makeBuildXML
[ -f "$propfile" ] && cp $propfile $sandbox/build.properties
exit 0

