#!/usr/bin/perl
# Werkt index.html bij met de actuele verwachting voor het Hullabaloo-weekend.
# Draait op GitHub Actions. Haalt de cijfers bij Open-Meteo en schrijft ze in de pagina.
# Bij twijfel faalt dit script liever dan dat het onzin op de site zet.

use strict;
use warnings;
use JSON::PP;
use Time::Local qw(timelocal);

$ENV{TZ} = 'Europe/Amsterdam';

my $HTML     = 'index.html';
my $LAT      = 53.2194;
my $LON      = 6.5665;
my $ZATERDAG = '2026-09-05';
my $ZONDAG   = '2026-09-06';
my $DOEL     = 25;      # graden waar Jesse op hoopt
my $ZON_MAX  = 14;      # schaal van het zonurenbalkje

my @DAGEN  = qw(zondag maandag dinsdag woensdag donderdag vrijdag zaterdag);
my @MAANDEN = ('', 'januari','februari','maart','april','mei','juni',
               'juli','augustus','september','oktober','november','december');

sub afronden { return int($_[0] + 0.5 * ($_[0] <=> 0)); }

# --- cijfers ophalen ---------------------------------------------------------
my $url = "https://api.open-meteo.com/v1/forecast"
        . "?latitude=$LAT&longitude=$LON"
        . "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,"
        . "precipitation_probability_max,sunshine_duration,daylight_duration,"
        . "cloud_cover_mean,wind_speed_10m_max,wind_direction_10m_dominant,weather_code"
        . "&timezone=Europe%2FAmsterdam&start_date=$ZATERDAG&end_date=$ZONDAG";

my $json;
for my $poging (1 .. 3) {
  $json = `curl -sS --max-time 30 "$url" 2>/dev/null`;
  last if defined $json && $json =~ /"daily"/;
  warn "Poging $poging bij Open-Meteo mislukt\n";
  sleep 5 if $poging < 3;
}
die "Open-Meteo gaf geen bruikbaar antwoord - pagina niet aangepast\n"
  unless defined $json && $json =~ /"daily"/;

my $d = decode_json($json)->{daily};
die "Onverwachte datums van Open-Meteo\n"
  unless $d->{time}[0] eq $ZATERDAG && $d->{time}[1] eq $ZONDAG;

# --- omrekenen ---------------------------------------------------------------
sub beaufort {
  my $kmh = shift;
  my @grens = (1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118);
  my $b = 0;
  for my $i (0 .. $#grens) { $b = $i + 1 if $kmh >= $grens[$i]; }
  return $b;
}

sub richting {
  my $graden = shift;
  my @r = qw(N NO O ZO Z ZW W NW);
  return $r[ int((($graden % 360) + 22.5) / 45) % 8 ];
}

sub weertype {
  my ($code, $bewolking) = @_;
  return 'Onbewolkt en zonnig'                if $code == 0;
  return 'Overwegend zonnig'                  if $code == 1;
  return 'Halfbewolkt, geregeld zon'          if $code == 2;
  return 'Overwegend bewolkt'                 if $code == 3;
  return 'Mistig'                             if $code == 45 || $code == 48;
  return 'Bewolkt met motregen'               if $code >= 51 && $code <= 57;
  return 'Bewolkt en regenachtig'             if $code >= 61 && $code <= 67;
  return 'Winters, kans op sneeuw'            if $code >= 71 && $code <= 77;
  return 'Wisselend bewolkt, enkele buien'    if $code >= 80 && $code <= 82;
  return 'Onweersbuien'                       if $code >= 95;
  return $bewolking > 60 ? 'Overwegend bewolkt' : 'Wisselend bewolkt';
}

my @dag;
for my $i (0, 1) {
  my $zon_ruw   = $d->{sunshine_duration}[$i] / 3600;
  my $daglengte = $d->{daylight_duration}[$i] / 3600;
  my $bewolking = $d->{cloud_cover_mean}[$i];
  # sunshine_duration is bij Open-Meteo veel te optimistisch: die geeft bijna de
  # hele dag zon terwijl het zwaar bewolkt is. Toetsen aan de bewolkingsgraad.
  my $zon_schat = $daglengte * (1 - $bewolking / 100);
  my $zon       = afronden($zon_ruw < $zon_schat ? $zon_ruw : $zon_schat);

  my $mm  = $d->{precipitation_sum}[$i];
  my $mm_tekst = $mm < 0.05 ? '0 mm' : sprintf('%.1f mm', $mm);
  $mm_tekst =~ s/\./,/;

  push @dag, {
    tmax      => afronden($d->{temperature_2m_max}[$i]),
    tmin      => afronden($d->{temperature_2m_min}[$i]),
    kans      => afronden($d->{precipitation_probability_max}[$i]),
    mm        => $mm,
    mm_tekst  => $mm_tekst,
    zon       => $zon,
    zonbalk   => afronden($zon / $ZON_MAX * 100),
    wind      => richting($d->{wind_direction_10m_dominant}[$i]) . ' '
                 . beaufort($d->{wind_speed_10m_max}[$i]) . ' bft',
    bft       => beaufort($d->{wind_speed_10m_max}[$i]),
    meta      => weertype($d->{weather_code}[$i], $bewolking),
  };
}
print "Zaterdag: $dag[0]{tmax}/$dag[0]{tmin} gr, $dag[0]{kans}% kans, $dag[0]{mm_tekst}, $dag[0]{zon}u zon, $dag[0]{wind}\n";
print "Zondag:   $dag[1]{tmax}/$dag[1]{tmin} gr, $dag[1]{kans}% kans, $dag[1]{mm_tekst}, $dag[1]{zon}u zon, $dag[1]{wind}\n";

# --- stickers ----------------------------------------------------------------
# Classificatie op de slechtste van de twee dagen; in de <small> beide waarden.
sub bereik {
  my ($a, $b, $eenheid) = @_;
  return "$a $eenheid" if $a == $b;
  return $a < $b ? "$a\x{e2}\x{80}\x{93}$b $eenheid" : "$b\x{e2}\x{80}\x{93}$a $eenheid";
}

my $temp_laag = $dag[0]{tmax} < $dag[1]{tmax} ? $dag[0]{tmax} : $dag[1]{tmax};
my $temp_hoog = $dag[0]{tmax} > $dag[1]{tmax} ? $dag[0]{tmax} : $dag[1]{tmax};
my $zon_laag  = $dag[0]{zon}  < $dag[1]{zon}  ? $dag[0]{zon}  : $dag[1]{zon};
my $kans_hoog = $dag[0]{kans} > $dag[1]{kans} ? $dag[0]{kans} : $dag[1]{kans};

my $cls_temp = $temp_laag >= $DOEL ? 'good' : $temp_laag >= 22 ? 'warn' : 'bad';
my $cls_zon  = $zon_laag  >= 7     ? 'good' : $zon_laag  >= 4  ? 'warn' : 'bad';
my $cls_droog= $kans_hoog <  20    ? 'good' : $kans_hoog <= 45 ? 'warn' : 'bad';

my $small_temp  = 'nu ' . bereik($dag[0]{tmax}, $dag[1]{tmax}, "\x{c2}\x{b0}C") . ' verwacht';
my $small_zon   = $dag[0]{zon} == $dag[1]{zon}
                ? "$dag[0]{zon} uur per dag"
                : ($zon_laag . ' tot ' . ($dag[0]{zon} > $dag[1]{zon} ? $dag[0]{zon} : $dag[1]{zon}) . ' uur per dag');
my $kans_bereik = bereik($dag[0]{kans}, $dag[1]{kans}, "%");
my $small_droog = "buienkans $kans_bereik";

# --- teksten -----------------------------------------------------------------
my $verdict = do {
  my @z;
  if ($temp_laag >= $DOEL) {
    push @z, "Je doel van $DOEL \x{c2}\x{b0}C wordt gehaald: $dag[0]{tmax} \x{c2}\x{b0}C op zaterdag en $dag[1]{tmax} \x{c2}\x{b0}C op zondag.";
  } elsif ($temp_hoog >= $DOEL) {
    my $welke = $dag[0]{tmax} >= $DOEL ? 'zaterdag' : 'zondag';
    push @z, "Het doel van $DOEL \x{c2}\x{b0}C wordt op $welke net gehaald, op de andere dag niet: $dag[0]{tmax} \x{c2}\x{b0}C op zaterdag en $dag[1]{tmax} \x{c2}\x{b0}C op zondag.";
  } else {
    my $tekort = $DOEL - $temp_hoog;
    push @z, "Het doel van $DOEL \x{c2}\x{b0}C wordt niet gehaald: $dag[0]{tmax} \x{c2}\x{b0}C op zaterdag en $dag[1]{tmax} \x{c2}\x{b0}C op zondag, dus $tekort graden onder de wens.";
  }
  if ($kans_hoog < 20) {
    push @z, "Het blijft naar verwachting droog \x{e2}\x{80}\x{94} de buienkans komt op geen van beide dagen boven de $kans_hoog procent uit.";
  } elsif ($kans_hoog <= 45) {
    push @z, "De buienkans van $kans_bereik is het voorbehoud: dat is het type dag waarop er ergens een bui overtrekt en het daarna weer opdroogt.";
  } else {
    push @z, "Reken op regen: met een buienkans van $kans_bereik en $dag[0]{mm_tekst} op zaterdag en $dag[1]{mm_tekst} op zondag blijf je niet droog.";
  }
  if ($zon_laag >= 7) {
    push @z, "De zon laat zich goed zien, $small_zon.";
  } elsif ($zon_laag >= 4) {
    push @z, "De zon breekt er geregeld doorheen, $small_zon.";
  } else {
    push @z, "Veel zon zit er niet in, $small_zon.";
  }
  join(' ', @z);
};

my $note = do {
  my @z;
  my $nacht_laag = $dag[0]{tmin} < $dag[1]{tmin} ? $dag[0]{tmin} : $dag[1]{tmin};
  if ($temp_hoog >= 22) {
    push @z, "Overdag is een T-shirt prima, maar met " . bereik($dag[0]{tmin}, $dag[1]{tmin}, "\x{c2}\x{b0}C") . " in de nacht wordt het na zonsondergang fris \x{e2}\x{80}\x{94} neem een trui mee voor de avondshows.";
  } else {
    push @z, "Met " . bereik($dag[0]{tmax}, $dag[1]{tmax}, "\x{c2}\x{b0}C") . " overdag en " . bereik($dag[0]{tmin}, $dag[1]{tmin}, "\x{c2}\x{b0}C") . " 's nachts is een trui overdag al geen overbodige luxe.";
  }
  if ($kans_hoog > 45) {
    push @z, "Een regenjas is geen twijfelgeval meer, die gaat mee.";
  } elsif ($kans_hoog >= 20) {
    push @z, "Neem een dun regenjack mee: bij een buienkans van $kans_hoog procent wil je niet doorweekt bij de avondacts staan.";
  }
  my $bft_hoog = $dag[0]{bft} > $dag[1]{bft} ? $dag[0]{bft} : $dag[1]{bft};
  if ($bft_hoog >= 5) {
    push @z, "Er staat $bft_hoog bft; op het open veld in het Stadspark voel je dat goed.";
  } elsif ($bft_hoog >= 4) {
    push @z, "Met $bft_hoog bft voel je de wind vooral op het open veld.";
  }
  join(' ', @z);
};

# --- dagenteller en datum ----------------------------------------------------
my @nu = localtime(time);
my $vandaag = timelocal(0, 0, 12, $nu[3], $nu[4], $nu[5]);
my $zat     = timelocal(0, 0, 12, 5, 8, 126);   # 5 september 2026
my $over    = afronden(($zat - $vandaag) / 86400);

my ($teller, $label);
if    ($over >  1) { $teller = $over;      $label = 'dagen';    }
elsif ($over == 1) { $teller = 1;          $label = 'dag';      }
else               { $teller = 'vandaag';  $label = 'festival'; }

my $datum = $DAGEN[$nu[6]] . ' ' . $nu[3] . ' ' . $MAANDEN[$nu[4] + 1] . ' ' . ($nu[5] + 1900);
print "Teller: $teller $label | Datum: $datum\n";


# --- HTML bijwerken ----------------------------------------------------------
# Alles werkt op ruwe bytes: het bestand en dit script zijn allebei UTF-8, dus
# de losse tekens matchen byte voor byte. Geen 'use utf8' - dat zou dat breken.
open(my $in, '<:raw', $HTML) or die "Kan $HTML niet openen: $!\n";
my $html = do { local $/; <$in> };
close $in;
my $origineel = $html;

# dagenteller
$html =~ s{<div class="count">.*?</div>}
          {<div class="count"><b>$teller</b><span>$label</span></div>}s
  or die "Kon de dagenteller niet vinden\n";

# stickers
my $pills = qq{<span class="pill $cls_temp">$DOEL \x{c2}\x{b0}C <small>$small_temp</small></span>\n}
          . qq{      <span class="pill $cls_zon">Zon <small>$small_zon</small></span>\n}
          . qq{      <span class="pill $cls_droog">Droog <small>$small_droog</small></span>};
$html =~ s{<div class="checks">.*?</div>}
          {<div class="checks">\n      $pills\n    </div>}s
  or die "Kon de stickers niet vinden\n";

# alinea onder de stickers
$html =~ s{(<div class="checks">.*?</div>)(\s*)<p>.*?</p>}
          {$1$2<p>$verdict</p>}s
  or die "Kon de alinea onder de stickers niet vinden\n";

# de twee dagkaarten
sub kaart {
  my ($blok, $w) = @_;
  $blok =~ s{(<div class="day-meta">).*?(</div>)}
            {$1$w->{meta} \x{c2}\x{b7} 12:00\x{e2}\x{80}\x{93}00:00$2}s
    or die "day-meta niet gevonden\n";
  $blok =~ s{(<div class="temp">).*?(</div>)}
            {$1$w->{tmax}\x{c2}\x{b0} <span>/ $w->{tmin}\x{c2}\x{b0} 's nachts</span>$2}s
    or die "temp niet gevonden\n";
  $blok =~ s{(<span class="label">Buienkans</span>\s*<span class="measure"><span class="bar"><i style="width:)\d+(%"></i></span><span class="val">)[^<]*(</span>)}
            {$1$w->{kans}$2$w->{kans} %$3}s
    or die "buienkans niet gevonden\n";
  $blok =~ s{(<span class="label">Neerslag</span><span class="val">)[^<]*(</span>)}
            {$1$w->{mm_tekst}$2}s
    or die "neerslag niet gevonden\n";
  $blok =~ s{(<span class="label">Zonuren</span>\s*<span class="measure"><span class="bar"><i style="width:)\d+(%"></i></span><span class="val">)[^<]*(</span>)}
            {$1$w->{zonbalk}$2$w->{zon} uur$3}s
    or die "zonuren niet gevonden\n";
  $blok =~ s{(<span class="label">Wind</span><span class="val">)[^<]*(</span>)}
            {$1$w->{wind}$2}s
    or die "wind niet gevonden\n";
  return $blok;
}

my $i = 0;
my $kaarten = ($html =~ s{<article class="day">.*?</article>}{ kaart($&, $dag[$i++]) }gse);
die "Verwachtte 2 dagkaarten, vond $kaarten\n" unless $kaarten == 2;

# praktische notitie
$html =~ s{<p class="note"><strong>Praktisch:</strong>.*?</p>}
          {<p class="note"><strong>Praktisch:</strong> $note</p>}s
  or die "Kon de praktische notitie niet vinden\n";

# datum in de footer
$html =~ s{(Laatst bijgewerkt: ).*?(\. Cijfers:)}
          {$1$datum$2}s
  or die "Kon de datum in de footer niet vinden\n";

# --- controle en wegschrijven ------------------------------------------------
die "Resultaat is verdacht kort - niet weggeschreven\n" if length($html) < 8000;
for my $rest ('width:%', '<b></b>', 'NaN', 'HASH(0x') {
  die "Rommel in het resultaat gevonden: $rest\n" if index($html, $rest) >= 0;
}

if ($html eq $origineel) {
  print "Niets veranderd.\n";
  exit 0;
}

open(my $uit, '>:raw', $HTML) or die "Kan $HTML niet schrijven: $!\n";
print $uit $html;
close $uit;
print "index.html bijgewerkt.\n";
