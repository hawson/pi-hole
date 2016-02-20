#!/bin/bash
# http://pi-hole.net
# Compiles a list of ad-serving domains by downloading them from multiple sources 

# This script should only be run after you have a static IP address set on the Pi
#piholeIP=$(hostname -I)
piholeIP='192.168.1.15 fd00::5054:ff:feae:a812'
piholeIP='127.0.0.1'

# Ad-list sources--one per line in single quotes
sources=('https://adaway.org/hosts.txt'
'http://adblock.gjtech.net/?format=unix-hosts'
'http://adblock.mahakala.is/'
'http://hosts-file.net/.%5Cad_servers.txt'
'http://www.malwaredomainlist.com/hostslist/hosts.txt'
'http://pgl.yoyo.org/adservers/serverlist.php?'
'http://someonewhocares.org/hosts/hosts'
'http://winhelp2002.mvps.org/hosts.txt')

# Variables for various stages of downloading and formatting the list
piholeDir=.
confdir=$piholeDir
origin=/BAD_USING_ORIGIN


#Where tmp lists are stored, working space for tmp files
tmp_dir=/tmp/pihole

rm $tmp_dir/tmp*

#cache time, in seconds
cache_age=3600
cache_file=$tmp_dir/cache_file.txt

conf_file=$conf_dir/pihole.conf
justDomainsExtension=domains

aggregate_file=$tmp_dir/aggregate.txt

blacklist=$piholeDir/blacklist.txt
whitelist=$piholeDir/whitelist.txt

final_output_file=$piholeDir/pihole_hosts.lst

# After setting defaults, check if there's local overrides
if [[ -r $piholeDir/pihole.conf ]];then
    echo "** Loading $conf_file"
	. $conf_file
fi

# Create the pihole resource directory if it doesn't exist.  Future files will be stored here
if [[ ! -d $tmp_dir ]];then
	echo "** Creating working $tmp_dir directory..."
	mkdir $tmp_dir
fi


function clean_list {
    file=$1
    saveLocation=$2

	if [[ -s "$file" ]];then
        echo -n "Cleaning $file..."
		# Remove comments and print only the domain name
		# Most of the lists downloaded are already in hosts file format but the spacing/formating is not contigious
		# This helps with that and makes it easier to read
		# It also helps with debugging so each stage of the script can be researched more in depth
		awk '($1 !~ /^#/) { if (NF>1) {print $2} else {print $1}}' $file | \
			sed -nr -e 's/\.{2,}/./g' -e '/\./p' > $saveLocation
		echo "Done."
	else
		echo "Skipping list because it is empty."
	fi

}

function fetch_list {
    url=$1

	# Get just the domain from the URL
	domain=$(echo "$url" | cut -d'/' -f3)
	
	# Save the file as list.#.domain
	saveLocation=$tmp_dir/list.$i.$domain.$justDomainsExtension

    touch -d "-$cache_age seconds" $cache_file
    if [ $cache_file -ot $saveLocation ]; then
        echo "Cache not expired: $saveLocation" 
        return
    fi


	agent="Mozilla/10.0"
	
	echo -n "Getting $domain list... "

	# Use a case statement to download lists that need special cURL commands 
	# to complete properly and reset the user agent when required
	case "$domain" in
		"adblock.mahakala.is") 
			agent='Mozilla/5.0 (X11; Linux x86_64; rv:30.0) Gecko/20100101 Firefox/30.0'
			cmd="curl -e http://forum.xda-developers.com/"
			;;
		
		"pgl.yoyo.org") 
			cmd="curl -d mimetype=plaintext -d hostformat=hosts"
			;;

		# Default is a simple curl request
		*) cmd="curl"
	esac

	# tmp file, so we don't have to store the (long!) lists in RAM
    # Note that we check against the ultimate saveLocation, and not
    # the tmpfile (this is because we clean raw list after getting it)
	tmpfile=`mktemp --tmpdir=$tmp_dir`
	timeCheck=""
	if [ -r $saveLocation ]; then 
		timeCheck="-z $saveLocation"
	fi

	CMD="$cmd -s $timeCheck -A '$agent' $url > $tmpfile"
	echo "running [$CMD]"
    $cmd -s $timeCheck -A "$agent" $url > $tmpfile

    clean_list $tmpfile $saveLocation

	# cleanup
	rm -vf $tmpfile
}


function consolidate_list {
    aggregate_file=$1
    output=$2
    whitelist=$3

    numberOf=$(wc -l $aggregate_file)
	echo "** $numberOf aggregate domains..."

    sort -u $aggregate_file | sed "s/^/$piholeIP /" > $output

    numberOf=$(wc -l $output)
	echo "** $numberOf deduped domains..."

    if [ -r "$whitelist" ]; then
        grep -v -f $whitelist $output > $tmp_dir/tmp.final
        mv $tmp_dir/tmp.final $output
    fi
}

# Loop through domain list.  Download each one and remove commented lines (lines beginning with '# 'or '/') and blank lines
for ((i = 0; i < "${#sources[@]}"; i++))
do
	url=${sources[$i]}
    fetch_list $url	
done


# Find all files with the .domains extension and compile them into one file and remove CRs
echo "** Aggregating lists of domains..."
find $tmp_dir -type f -name "*.$justDomainsExtension" | xargs cat | tr -d '\r' > $aggregate_file


# Append blacklist entries if they exist
if [[ -r $blacklist ]];then
    clean_blacklist=$tmp_dir/cleaned_blacklist.txt
    clean_list $blacklist $clean_blacklist
    numberOf=$(wc -l $clean_blacklist)
	plural=""; [[ "$numberOf" != "1" ]] && plural=s
	echo "** Blacklisting $numberOf domain${plural}..."
	cat $clean_blacklist >> $aggregate_file
fi

# Prevent our sources from being pulled into the hole
clean_whitelist=$tmp_dir/cleaned_whitelist.txt

plural=; [[ "${#sources[@]}" != "1" ]] && plural=s
echo "** Whitelisting ${#sources[@]} ad list source${plural}..."
for url in ${sources[@]}
do
    echo "$url" | awk -F '/' '{print "^"$3"$"}' | sed 's/\./\\./g' >> $clean_whitelist
done


# Whitelist (if applicable) then remove duplicates and format for dnsmasq
if [[ -r "$whitelist" ]];then
	# Remove whitelist entries
    clean_list $whitelist $clean_whitelist


    sed -i -e 's/^/^/' -e 's/\./\\./g' -e 's/$/$/' $clean_whitelist 

    numberOf=$(wc -l $clean_whitelist)
	plural=; [[ "$numberOf" != "1" ]] && plural=s
	echo "** Whitelisting $numberOf domain${plural}..."

fi


# Dedupe, etc
consolidate_list $aggregate_file $final_output_file $clean_whitelist

