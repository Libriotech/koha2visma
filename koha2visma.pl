#!/usr/bin/perl

# Copyright 2020 BibLibre
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use strict;
use warnings;

BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

use Koha::Account::Lines;
use Koha::DateUtils qw /dt_from_string/;
use Koha::Patrons;
use Koha::Script -cron;

use C4::Log;
use Getopt::Long;
use POSIX qw(strftime);
use Data::Dumper;

my $artnr           = undef;
my @categories      = undef;
my $faktgrp         = undef;
my $konto           = undef;
my $minoverdues     = undef;
my $municipalcode   = undef;
my $personorgnrcode = undef;
my $rutinkod        = undef;

my $test_mode       = 0;
my $help            = 0;
my $verbose         = 0;

GetOptions(
    'artnr:s'         => \$artnr,
    'category:s'      => \@categories,
    'faktgrp:s'       => \$faktgrp,
    'konto:s'         => \$konto,
    'municipalcode:s' => \$municipalcode,
    'min-overdues:s'  => \$minoverdues,
    'person-orgnr:s'  => \$personorgnrcode,
    'rutincode:s'     => \$rutinkod,
    'testmode'        => \$test_mode,
    'h|help'          => \$help,
    'v|verbose'       => \$verbose,
);
my $usage = << 'ENDUSAGE';

This script generates a file for invoicing overdues & debts.

This script has the following parameters :
 Mandatory parameters:
    --artnr - article number - 13 characters code
    --category - patron categories to include (repeatable)
    --faktgrp - 2 characters code
    --konto - code
    --municipalcode - 5 characters code
    --person-orgnr - extended patron attribute code in which person/orgnr will be
      retrieved
    --rutincode - 3 characters code

 Optional parameters:
    --min-overdues - number of days before including the account line
    --testmode: do not change the itemlost value of items
    -h --help: this message
    -v --verbose: provides verbose output to STDOUT
ENDUSAGE

die $usage if $help;

die "\n--artnr is missing\n$usage" unless $artnr;
die "\n--artnr is longer than 13 characters\n$usage" if (length $artnr > 13);
die "\n--faktgrp is missing\n$usage" unless $faktgrp;
die "\n--faktgrp length should be 2\n$usage" unless (length $faktgrp == 2);
die "\n--konto is missing\n$usage" unless $konto;
die "\n--konto is longer than 45 characters\n$usage" if (length $konto > 45);
die "\n--municipalcode is missing\n$usage" unless $municipalcode;
die "\n--municipalcode length should be 5\n$usage" unless (length $municipalcode == 5);
die "\n--person-orgnr is missing\n$usage" unless $personorgnrcode;
die "\n$personorgnrcode is not a valid patron extended attribute code (or there isn't at least one patron with a value for this extended attribute)\n$usage" unless (Koha::Patron::Attributes->count({ code => $personorgnrcode }) >= 1);
die "\n--rutincode is missing\n$usage" unless $rutinkod;
die "\n--rutincode length should be 3\n$usage" unless (length $rutinkod == 3);

cronlogaction();

$konto = sprintf("%-45s", $konto);

my $extftg      = $municipalcode;
my $vsamhkod    = "  ";
my $radnr       = "000";
my $radnrtxt    = "000";
my $framstdat   = strftime("%Y%m%d", localtime());
my $framstkloc  = strftime("%H%M%S", localtime());
my $ordernr     = "00000";

my $faktlopnr   = " " x 10; # ? spaces in example file
my $extknr      = " " x 16; # ? spaces in example file
my $kundnr      = " " x 8;  # ? spaces in example file
my $conamn1     = " " x 36; # ? spaces in example file
my $conamn2     = " " x 36; # ? spaces in example file
my $utskrtyp    = "  ";     # ? spaces in example file
my $autognr     = " " x 18; # ? spaces in example file
my $orgkod      = " " x 10; # ? spaces in example file
my $faktdat     = " " x 8;  # billing date ? spaces in example file
my $forfdat     = " " x 8;  # expiration date ? spaces in example file
my $bokfdat     = strftime("%Y%m%d", localtime());
my $vrefnamn    = " " x 36; # ? spaces in example file
my $vrefadress  = " " x 27; # ? spaces in example file
my $vreftelefon = " " x 36; # ? spaces in example file
my $vreffxanr   = " " x 36; # ? spaces in example file
my $vrefmail    = " " x 50; # ? spaces in example file
my $fomdat      = $framstdat; # ?
my $tomdat      = " " x 8;  # ? spaces in example file

my $filler = " " x 228;
# Item type 10 Introduction item.
print "10${extftg}${rutinkod}${ordernr}${vsamhkod}${radnr}${radnrtxt}${framstdat}${framstkloc}${faktdat}${forfdat}${bokfdat}EZF${filler}\n";

$bokfdat     = " " x 8;

my $order = 0;
my $totalitems = 0;

# For each category
my @patrons;
if (scalar(@categories > 1)) {
    @patrons = Koha::Patrons->search({ categorycode => \@categories });
} else {
    @patrons = Koha::Patrons->search();
}
foreach my $patron (@patrons) {
    next unless $patron->checkouts->count;
    my $checkouts = $patron->checkouts;
    my @selected_checkouts;

    while (my $checkout = $checkouts->next) {
        my $item = Koha::Items->find({ itemnumber => $checkout->itemnumber });
        next if ($item->itemlost == 3);
        if ($minoverdues) {
            my $dtdate = dt_from_string($checkout->date_due, 'sql');
            my $dtnow = DateTime->now();
            my $cmp = DateTime->compare( $dtdate, $dtnow );
            # Make sure we only proceed with dates in the past, not in the future
            if ( $cmp == -1 ) {
                my $age = $dtdate->delta_days($dtnow);
                $age = $age->in_units('days');
                if ($age >= $minoverdues) {
                    push @selected_checkouts, $checkout;
                    say STDERR "itemnumber: " . $checkout->itemnumber . ", date_due: " . $checkout->date_due . " , age: $age" if $verbose;
                }
            }
        } else {
            push @selected_checkouts, $checkout;
        }
    }
    next unless @selected_checkouts;
    my $personorgnr = " " x 12;
    my $attributes = Koha::Patron::Attributes->find({ code => $personorgnrcode, borrowernumber => $patron->borrowernumber });
    if ($attributes) {
        my @dateofbirtharray = split /-/, $patron->dateofbirth;
        my $yearofbirth = $dateofbirtharray[0];
        my $attributedate = substr($attributes->attribute, 2);
        $personorgnr = sprintf("%-12.12s", $yearofbirth . $attributedate);
    }

    # Item type 30 Invoice item 1
    $order++;
    $ordernr = sprintf("%05d", $order);
    my $name = sprintf("%-36.36s", $patron->firstname . " " . $patron->surname);
    my $adress = sprintf("%-27.27s", $patron->address . " " . $patron->address2);
    my $itemno = sprintf("%-8.8s", $patron->zipcode);
    my $ort = sprintf("%-18.18s", $patron->city);
    my $landskod = "   "; # Always sweden ?
    $filler = " " x 3;

    print "30${extftg}${rutinkod}${ordernr}${vsamhkod}${radnr}${radnrtxt}${faktgrp}${faktlopnr}${extknr}${personorgnr}${kundnr}${name}${adress}";
    print "${itemno}${ort}${landskod}${conamn1}${conamn2}${utskrtyp}${autognr}${orgkod}${faktdat}${forfdat}${bokfdat}${vrefnamn}${vrefadress}";
    print "${vreftelefon}${vreffxanr}${vrefmail}${filler}\n";

    my $itemcount = 0;
    foreach my $checkout (@selected_checkouts) {
        next unless $checkout->itemnumber;

        $itemcount++;
        $totalitems++;
        # Item type 50 Article item
        $filler = " " x 15;
        my $artnr = sprintf("%-13s", $artnr);
        my $avsernamn = " " x 30;
        my $kontonamn = " " x 30;
        my $signantal = "+"; # ? always + ?
        my $antal = "00000000100";
        my $sort = " " x 6; # ?
        my $avserperiod = " " x 13;
        my $signapris = "+";
        my $apris = "0" x 13;
        my $signrabsats = " ";
        my $rabsats = "0" x 5;
        my $signbel = " ";
        my $bel = "0" x 13;
        my $signmomssats = " ";
        my $momssats = "0" x 4;
        my $signmomsbel = " ";
        my $momsbel = "0" x 9;
        my $omrade = " " x 3;
        my $kategori = " " x 3;
        my $konto100 = " " x 100;
        my $radnrcount = sprintf("%03d", $itemcount);
        my $benamn;

        my $item = Koha::Items->find({ itemnumber => $checkout->itemnumber });
        my $biblio = Koha::Biblios->find({ biblionumber => $item->biblionumber });
        my $title = $biblio->subtitle ? $biblio->title . ' - ' . $biblio->subtitle : $biblio->title;
        $benamn = sprintf("%-30.30s", $title);
        if ($item->replacementprice) {
            $apris = sprintf("%014.2f", $item->replacementprice);
            $apris =~ s/\.//;
        } else {
            my $itemtype = Koha::ItemTypes->find({ itemtype => $item->effective_itemtype() });
            if ($itemtype->defaultreplacecost) {
                $apris = sprintf("%014.2f", $itemtype->defaultreplacecost) if ($itemtype->defaultreplacecost);
                $apris =~ s/\.//;
            }
        }
        items_hook($item);

        print "50${extftg}${rutinkod}${ordernr}01${radnrcount}${radnrtxt}${fomdat}${tomdat}${artnr}${benamn}${avsernamn}${konto}${kontonamn}";
        print "${signantal}${antal}${sort}${avserperiod}${signapris}${apris}${signrabsats}${rabsats}${signbel}${bel}${signmomssats}${momssats}${signmomsbel}";
        print "${momsbel}${omrade}${kategori}${konto100}${filler}\n";

        # Item type 60 Text entry 2
        #$filler = " " x 206;
        #print "60${extftg}${rutinkod}${ordernr}${vsamhkod}${radnr}${radnrtxt}${texttyp}${text}${filler}\n";
    }
    patrons_hook($patron);
}

# Item type 35 Invoice item 2 (Optional)
#$filler = " " x 108;
#print "35${extftg}${rutinkod}{$ordernr}${vsamhkod}${radnr}${radnrtxt}${mobiltelefon}${faxnr}${email}${valutakod}${telefon}${filler}\n";

# Item type 36 Invoice item 3 (Optional)
#$filler = "";
#print "36${extftg}${rutinkod}{$ordernr}${vsamhkod}${radnr}${radnrtxt}${extknr}${personorgnr}${kundnr}${name}${adress}${postnr}${ort}";
#print "${landskod}${conamn1}${comamn2}${telefon}${email}\n";

# Item type 40 Text entry 1
#$filler = " " x 206;
#print "40${extftg}${rutinkod}${ordernr}${vsamhkod}${radnr}${radnrtxt}${texttyp}${text}${filler}\n";


# Item type 90 Termination record
$filler = " " x 243;
my $antframord = sprintf("%05d", $order);
my $andframrad = sprintf("%05d", $totalitems);
my $signframbel = '+';
my $frambel = "0" x 15; # ? zeroes in example file
print "90${extftg}${rutinkod}99999${vsamhkod}${radnr}${radnrtxt}${antframord}${andframrad}${signframbel}${frambel}${filler}\n";

# call hook_function for items
sub items_hook {
    my $item = shift;
    return unless $item;

    # Some item processing, for instance:
    # $item->set({ itemnotes => "processed"})->store;

    if ( $test_mode == 0 ) {
        $item->set({ itemlost => 3 })->store;
    }

}

# call hook_function for patrons
sub patrons_hook {
    my $patron = shift;
    return unless $patron;

    # Some patron processing, for instance:
    # $patron->set({ surname => $patron->surname . " (processed)" })->store;
}
