#!/bin/bash

set -e

PN="${BASH_SOURCE[0]##*/}"
PD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

confpath="${PD}/${PN%.sh}.conf.sh"

[ -f "${confpath}" ] && source "${confpath}"

curlopt="-s -o /dev/null"
curlopt="-s"
curl="curl ${curlopt}"
esurl="${ESURL:-http://127.0.0.1:9200/index/type}"
solrurl="${SOLRURL:-http://127.0.0.1:8983/solr/core0}"
outdir="${OUTDIR:-${PD}}"

function usage() {
	cat <<EOF
Usage: ${PN} -h|small|main
Config file: '${confpath}'
             load config before running
Environment:
  ESURL:     elasticsearch http api url
             e.g. http://127.0.0.1:9200/index/type
             current: '${esurl}'
  SOLRURL:   solr http api url
             e.g. http://127.0.0.1:8983/solr/core0
             current: '${solrurl}'
  OUTDIR:    test result output directory
             e.g. /tmp
             current: '${outdir}'
EOF
}

function test_es() {
	local q="${1}"
	http_proxy="" ${curl} "${esurl}/_search?pretty=1&size=0" -d '
{
	"query":{
		"filtered":{
			"query":{
				"query_string":{
					"query":"'"${q}"'"
				}
			}
		}
	}
}
'
}

function test_es_facet() {
	local q="${1}"
	http_proxy="" ${curl} "${esurl}/_search?pretty=1&size=0" -d '
{
	"query":{
		"filtered":{
			"query":{
				"query_string":{
					"query":"'"${q}"'"
				}
			}
		}
	},
	"facets":{
		"ipcs_pcs":{
			"terms":{
				"field":"ipcs_pcs",
				"size":10
			}
		}
	}
}
'
}

function test_solr() {
	local q="${1}"
	http_proxy="" ${curl} "${solrurl}/select?wt=json&indent=true&rows=0" -d "q=${q}"
}

function test_solr_facet() {
	local q="${1}"
	http_proxy="" ${curl} "${solrurl}/select?rows=0&wt=json&indent=true&facet=true&facet.field=ipcs_pcs&facet.limit=10" -d "q=${q}"
}

function gen_text() {
	local words="${1}"
	local para="${2}"
	curl -s 'http://www.dummytextgenerator.com/' \
		-A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.65 Safari/537.36' \
		-d "ftype=2&fnumwords=${words}&fnumparagraphs=${para}&fsubmit=Generate" \
		| grep " end text " | awk -F '</?p>' '{for(i=1;i<NF;i++){print $i}}' | sed '/^\s*$/d'
}

function time_cmd() {
	{ time {
		"$@"
	} } 2>&1 1>/dev/null | sed -n "2p" | sed "s/^[^\t]*\t//g; s/^/scale=0;1000*(/; s/m/*60+/; s|s$|)/1|" | bc
}

function rand_test() {
	local f="${1}"
	local qs="${2}"
	local n="$(wc -l <<<"${qs}")"
	local q
	local i

	{
		for ((i=1 ; i<=n ; i++)) ; do
			q="$(sed -n "${i}p" <<<"${qs}")"
			echo "elasticsearch query: ${q}"
			time_cmd test_es "${q}"
			echo "solr query: ${q}"
			time_cmd test_solr "${q}"
			echo "elasticsearch facet: ${q}"
			time_cmd test_es_facet "${q}"
			echo "solr facet: ${q}"
			time_cmd test_solr_facet "${q}"
		done
	} > "${f}"
}

function calc_std() {
	local group="${1}"
	grep -A 1 --no-group-separator "${group}" | sed -n "/^[[:digit:]]/p" | awk '
	BEGIN {
		i=0;
		gapname[i]="0";
		gap[i++]=0;
		gapname[i]="5ms";
		gap[i++]=5;
		gapname[i]="15ms";
		gap[i++]=15;
		gapname[i]="30ms";
		gap[i++]=30;
		gapname[i]="50ms";
		gap[i++]=50;
		gapname[i]=".1s";
		gap[i++]=100;
		gapname[i]=".5s";
		gap[i++]=500;
		gapname[i]="1s";
		gap[i++]=1000;
		gapname[i]="5s";
		gap[i++]=5000;
		gaplen=i;
		sum=0;
		sumsq=0;
	}
	{
		sum += $1;
		sumsq += ($1)^2;
		for (i=0;i<gaplen;i++) {
			if ($1 < gap[i]) {
				slot[i-1]++;
				break;
			}
		}
		if ($1 >= gap[gaplen-1]) {
			slot[gaplen-1]++;
		}
	}
	END {
		printf "%6s %7s  ", "avg", "std";
		for (i=0;i<gaplen;i++) {
			printf " %5s", gapname[i];
		}
		printf "\n";

		avg=sum/NR;
		printf "%7.2f %8.3f", avg, sqrt( (sumsq/NR) - (avg^2) )
		for (i=0;i<gaplen;i++) {
			printf " %5d", slot[i];
		}
		printf "\n";
	}'
}

function summary_test() {
	local f="${1}"
	cat "${f}" | calc_std "elasticsearch query:" | sed "1s/^/ T /;2s/^/eq /"
	cat "${f}" | calc_std "solr query:" | sed "1d" | sed "s/^/sq /"
	cat "${f}" | calc_std "elasticsearch facet:" | sed "1d" | sed "s/^/ef /"
	cat "${f}" | calc_std "solr facet:" | sed "1d" | sed "s/^/sf /"
}

function small() {
	local qs
	local f

	mkdir -p "${outdir}"

	f="${outdir}/smalltest_sample.txt"
	echo "Generate random text ..."
	qs="$(gen_text 30 5)"
	echo "Collect test sample ..."
	rand_test "${f}" "${qs}"
	echo "Summarize test sample ..."
	summary_test "${f}" | tee "${outdir}/smalltest_summary.txt"
}

function main() {
	local qs
	local f

	mkdir -p "${outdir}"

	f="${outdir}/test_sample_01k.txt"
	echo "Generate random text ..."
	qs="$(gen_text 1000 500)"
	echo "Collect test sample ..."
	rand_test "${f}" "${qs}"
	echo "Summarize test sample ..."
	summary_test "${f}" | tee "${outdir}/test_summary_01k.txt"

	f="${outdir}/test_sample_03k.txt"
	echo "Generate random text ..."
	qs="$(gen_text 3000 500)"
	echo "Collect test sample ..."
	rand_test "${f}" "${qs}"
	echo "Summarize test sample ..."
	summary_test "${f}" | tee "${outdir}/test_summary_03k.txt"

	f="${outdir}/test_sample_09k.txt"
	echo "Generate random text ..."
	qs="$(gen_text 9000 500)"
	echo "Collect test sample ..."
	rand_test "${f}" "${qs}"
	echo "Summarize test sample ..."
	summary_test "${f}" | tee "${outdir}/test_summary_09k.txt"

	f="${outdir}/test_sample_25k.txt"
	echo "Generate random text ..."
	qs="$(gen_text 25000 500)"
	echo "Collect test sample ..."
	rand_test "${f}" "${qs}"
	echo "Summarize test sample ..."
	summary_test "${f}" | tee "${outdir}/test_summary_25k.txt"
}

if [ "$1" == "small" ] ; then
	small
elif [ "$1" == "main" ] ; then
	main
else
	usage
fi

