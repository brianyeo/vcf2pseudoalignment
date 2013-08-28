#!/usr/bin/env perl
# check_snps_nucmer.pl
# Purpose:  Given a pseudoalign-positions.tsv and list of closed/finished fasta files
# and a reference, runs nucmer to verify the SNPs called from the reference mapping pipeline to those in pseudoalign-positions.tsv.

use warnings;
use strict;

use Getopt::Long;
use Cwd qw(abs_path getcwd);
use File::Temp 'tempdir';
use Set::Scalar;
use File::Basename;
use Bio::SeqIO;
use Bio::LiveSeq::Mutation;
use Bio::SeqUtils;

my ($input_align,$genome,$output,$reference,$bad_positions_file,$verbose);
$verbose = 0;
my $keep_temp = 1;

sub parse_single_genome
{
	my ($genome_file, $reference, $out_dir, $changed_positions, $genome_name, $bad_positions) = @_;

	my %results;
	my %results_no_bad_positions;
	$results{$genome_name} = Set::Scalar->new;
	$results_no_bad_positions{$genome_name} = Set::Scalar->new;
	my $seen_changed_positions = {};

	my $cwd = getcwd;
	my $reference_name = basename($reference, '.fasta');

	my $delta_prefix = "${reference_name}_${genome_name}";
	my $snps_file_name = "$delta_prefix.snps";

	my $genome_file_abs_path = abs_path($genome_file);
	my $ref_file_abs_path = abs_path($reference);

	chdir $out_dir;
	my $command = "nucmer --prefix=$delta_prefix $ref_file_abs_path $genome_file_abs_path 2> $delta_prefix.nucmer.err.log 1> $delta_prefix.nucmer.out.log";
	print STDERR $command if ($verbose);
	system($command) == 0 or die "Could not execute \"$command\"";

	$command = "show-snps -CTH $delta_prefix.delta 2> $delta_prefix.delta.show-snps.log 1> $snps_file_name";
	print STDERR $command if ($verbose);
	system($command) == 0 or die "Could not execute \"$command\"";

	open(my $fh, "<$snps_file_name") or die "Could not open $snps_file_name";
	while(readline($fh))
	{
		chomp;
		my @fields = split(/\t/);
		my ($ref_pos, $ref, $alt, $ref_name) = ($fields[0],$fields[1],$fields[2],$fields[8]);
		die "error: undefined value for ref_pos" if (not defined $ref_pos);
		die "error: undefined value for ref" if (not defined $ref);
		die "error: undefined value for alt" if (not defined $alt);
		die "error: undefined value for ref_name" if (not defined $ref_name);
		next if ($ref !~ /^[ACTG]$/i or $alt !~ /^[ACTG]$/i);

		print STDERR "$genome_name: $ref_name\t$ref_pos\t$ref\t$alt\n" if ($verbose);
		if (defined $changed_positions->{$genome_name}{$ref_name}{$ref_pos})
		{
			my $original_position = $changed_positions->{$genome_name}{$ref_name}{$ref_pos}{'reference'};
			my $changed_position = $changed_positions->{$genome_name}{$ref_name}{$ref_pos}{'changed'};
			if ($changed_position ne $ref)
			{
				die "error: change on reference for $ref_name:$ref_pos [r:$original_position => r:$changed_position] did not work";
			}
			elsif ($original_position ne $alt)
			{
				print STDERR "picked up invalid reference call from snp in a changed position on reference $genome_name:$ref_name:$ref_pos should be [r:$original_position => r:$changed_position], was [r:$ref => r:$alt]\n";
				$results{$genome_name}->insert("$ref_name\t$ref_pos\t$original_position\t$alt");
				if (not exists $bad_positions->{"${ref_name}_${ref_pos}"})
				{
					$results_no_bad_positions{$genome_name}->insert("$ref_name\t$ref_pos\t$original_position\t$alt");
				}
			}
			else
			{
				$results{$genome_name}->insert("$ref_name\t$ref_pos\t$original_position\t$alt");
				if (not exists $bad_positions->{"${ref_name}_${ref_pos}"})
				{
					$results_no_bad_positions{$genome_name}->insert("$ref_name\t$ref_pos\t$original_position\t$alt");
				}
			}

			$seen_changed_positions->{$ref_name}{$ref_pos} = 1;
		}
		else
		{
			$results{$genome_name}->insert("$ref_name\t$ref_pos\t$ref\t$alt");
			if (not exists $bad_positions->{"${ref_name}_${ref_pos}"})
			{
				$results_no_bad_positions{$genome_name}->insert("$ref_name\t$ref_pos\t$ref\t$alt");
			}
		}
	}
	close($fh);
	chdir ($cwd);

	# check for any positions where we swapped the reference base and it wasn't identified as a SNP
	# (sign of an invalid reference base call)
	my $genome_changed_positions = $changed_positions->{$genome_name};
	for my $ref_name (keys %$genome_changed_positions)
	{
		my $ref_name_table = $genome_changed_positions->{$ref_name};
		for my $ref_pos (keys %$ref_name_table)
		{
			my $ref = $ref_name_table->{$ref_pos}{'reference'};
			my $changed = $ref_name_table->{$ref_pos}{'changed'};
			if (not exists $seen_changed_positions->{$ref_name}{$ref_pos})
			{
				$results{$genome_name}->insert("$ref_name\t$ref_pos\t$ref\t$changed");
				if (not exists $bad_positions->{"${ref_name}_${ref_pos}"})
				{
					$results_no_bad_positions{$genome_name}->insert("$ref_name\t$ref_pos\t$ref\t$changed");
				}
			}
		}
	}

	return (\%results,\%results_no_bad_positions);
}

sub generate_genome_file_mapping
{
	my ($genomes_dir, $genome_names) = @_;

	my %genome_file_map; # maps {genome_name => closed_genome_file}
	opendir(my $d, $genomes_dir) or die "Could not open $genomes_dir: $!";
	while (my $genome_file = readdir $d)
	{
		next if ($genome_file !~ /\.fasta$/);
		my $curr_file = "$genomes_dir/$genome_file";
		print STDERR "curr_file=$curr_file\n";
		print STDERR "genome_file=$genome_file\n";

		# find genome name which appears at the beginning of the file name 
		for my $curr_name (@$genome_names)
		{
			print STDERR "checking $curr_name against $genome_file\n";
			if ($genome_file =~ /^$curr_name/)
			{
				if (defined $genome_file_map{$curr_name})
				{
					die "Error: found duplicate files for $curr_name: $curr_file and ".
						$genome_file_map{$curr_name}."\n";
				}
				else
				{
					$genome_file_map{$curr_name} = $curr_file;
				}
			}
		}
	}
	closedir($d);

	return \%genome_file_map;
}

sub generate_reference_contig_map
{
	my ($reference) = @_;

	my %contig_map;
	my $ref_io = Bio::SeqIO->new(-file=>"<$reference", -format=>"fasta");
	die "error: could not read $reference" if (not defined $ref_io);

	while (my $seq = $ref_io->next_seq)
	{
		$contig_map{$seq->display_id} = $seq;
	}

	return \%contig_map;
}

sub get_reference_length
{
	my ($reference) = @_;
	my $length = 0;

	my $io = Bio::SeqIO->new(-file=>"<$reference", -format=>"fasta");
	die "error: could not read $reference" if (not defined $io);

	while (my $seq = $io->next_seq)
	{
		$length += $seq->length;
	}

	return $length;
}

sub determine_genome_name
{
	my ($genomes_core_snp, $genome) = @_;
	my $genome_name = undef;
	my $genome_file = basename($genome, '.fasta');

	for my $curr_name (keys %$genomes_core_snp)
	{
		if ($genome_file =~ /^$curr_name/)
		{
			die "error: already exists name in table for genome $genome, name $genome_name" if (defined $genome_name);
			$genome_name = $curr_name;
		}
	}

	return $genome_name;
}

sub parse_genome_nucmer
{
	my ($genome, $reference, $genomes_core_snp, $genome_name, $bad_positions) = @_;

	my $nucmer_set = undef;
	my $nucmer_set_no_bad_pos = undef;
	# map defining how to swap out bases in closed/finished genome to detect same as reference "snps"
	my $base_sub_map =
		{'A' => 'T', 'C' => 'G', 'G' => 'C', 'T' => 'A'};

	my $out_dir = tempdir("SNP_Check_XXXXXX", TMPDIR => 1, CLEANUP => $keep_temp);
	print STDERR "Tempdir=$out_dir\n" if ($verbose);

	my $reference_copy = "$out_dir/".basename($reference);
	my $genome_file_name = basename($genome);

	my %changed_positions;
	my $reference_contig_map = generate_reference_contig_map($reference);
	my $genome_core_snp = $genomes_core_snp->{$genome_name};
	if (not defined $genome_core_snp)
	{
		warn "warning: no genome_core_snp for $genome_name";
	}

	for my $chrom (keys %$genome_core_snp)
	{
		my $pos_map = $genome_core_snp->{$chrom};
		for my $pos (keys %$pos_map)
		{
			my $contig = $reference_contig_map->{$chrom};
			die "error: no contig found for $chrom" if (not defined $contig);
			my $ref_base = $pos_map->{$pos}->{'reference'};
			my $alt_base = $pos_map->{$pos}->{'alternative'};
			die "error: no ref_base for $genome_name:$chrom:$pos" if (not defined $ref_base);
			die "error: no alt_base for $genome_name:$chrom:$pos" if (not defined $alt_base);

			# if not snp but reference base, need to swap out for another base in reference file
			# in order to get nucmer + show-snps to detect
			if ($ref_base eq $alt_base)
			{
				my $swapped_base = $base_sub_map->{$ref_base};
				die "error: could not find alternative base for $ref_base" if (not defined $swapped_base);
				my $mutation = Bio::LiveSeq::Mutation->new(-seq => $swapped_base, -pos => $pos);
			
				Bio::SeqUtils->mutate($contig,$mutation);
				$changed_positions{$genome_name}{$chrom}{$pos} = {'reference' => $ref_base, 'changed' => $swapped_base};
				print STDERR "changed $genome_name:$chrom:$pos [r:$ref_base => r:$swapped_base, a:$alt_base]\n" if ($verbose);
			}
			else
			{
				print STDERR "kept $genome_name:$chrom:$pos [r:$ref_base, a:$alt_base]\n" if ($verbose);
			}
		}
	}

	my $out_io = Bio::SeqIO->new(-file=>">$reference_copy", -format=>"fasta");
	for my $contig (keys %$reference_contig_map)
	{
		$out_io->write_seq($reference_contig_map->{$contig});
	}
	print STDERR "Wrote changed reference to $reference_copy\n" if ($verbose);

	my ($genome_nucmer_set, $genome_nucmer_set_no_bad_pos) = parse_single_genome($genome,$reference_copy,$out_dir, \%changed_positions, $genome_name, $bad_positions);
	$nucmer_set = $genome_nucmer_set->{$genome_name};
	if (not defined $nucmer_set)
	{
		warn "nucer_set undefind for $genome_name, assuming no SNPs";
		$nucmer_set = Set::Scalar->new;
	}

	$nucmer_set_no_bad_pos = $genome_nucmer_set_no_bad_pos->{$genome_name};
	if (not defined $nucmer_set_no_bad_pos)
	{
		warn "nucer_set undefind for $genome_name, assuming no SNPs";
		$nucmer_set_no_bad_pos = Set::Scalar->new;
	}

	return ($nucmer_set,$nucmer_set_no_bad_pos);
}

sub build_pipeline_set
{
	my ($genome_name, $genomes_core_snp) = @_;

	my $pipeline_set = Set::Scalar->new;

	my $genome_snps_set = $genomes_core_snp->{$genome_name};
	if (not defined $genome_snps_set)
	{
		warn "warning: no genome_snps_set for $genome_name defined";
	}

	for my $chrom (keys %$genome_snps_set)
	{
		my $pos_map = $genome_snps_set->{$chrom};
		for my $pos (keys %$pos_map)
		{
			my $ref = $pos_map->{$pos}->{'reference'};
			my $alt = $pos_map->{$pos}->{'alternative'};

			$pipeline_set->insert("$chrom\t$pos\t$ref\t$alt");
		}
	}

	return $pipeline_set;
}

# returns a table mapping
# strain_id => chrom => pos => {'reference' => $ref_base, 'alternative' => $alt_base}
sub generate_core_genome_snps
{
	my ($input_align, $genome_file) = @_;

	open(my $fh, "<$input_align") or die "Could not open $input_align: $!";
	
	my $line = readline($fh);
	chomp($line);
	
	die "Error: no header line defined in $input_align" if ($line !~ /^#Chromosome\tPosition\tStatus\tReference/);
	my (undef,undef,undef,@strains) = split(/\t/,$line);
	die "Error: no strains defined in $input_align" if (@strains <= 0);
	die "Error: reference not in correct column" if ($strains[0] ne 'Reference');
	my %genomes_core_snp;

	# initialize empty table for each strain
	for my $strain (@strains)
	{
		$genomes_core_snp{$strain} = undef;
	}
	
	my $valid = 0;
	my $total = 0;
	while(my $line = readline($fh))
	{
		chomp $line;
		my @values = split(/\t/,$line);
	
		my ($chrom,$pos,$status,@dna) = @values;
	
		if (scalar(@dna) != scalar(@strains))
	        {
	                die "Error: line $line does not have same number of entries as header for $input_align";
	        }
		elsif ($status ne 'valid')
		{
			print STDERR "skipping over line \"$line\": invalid\n" if ($verbose);
		}
		else
		{
			$genomes_core_snp{$chrom}{$pos}{'status'} = $status;
			for (my $i = 1; $i < @dna; $i++)
			{
				$genomes_core_snp{$strains[$i]}{$chrom}{$pos} = {'reference' => $dna[0], 
					'alternative' => $dna[$i]};
			}
			$valid++;
		}
		$total++;
	}
	close $fh;
	
	print STDERR "Kept $valid valid positions out of $total total positions\n" if ($verbose);

	return \%genomes_core_snp;
}

sub usage
{
	"Usage: $0 -i [pseudoalign-positions.tsv] -r [reference file] -g [genome file] [-v]\n".
	"Parameters:\n".
	"\t-i|--input-align:  Input file (pseudoalign-positions.tsv generated by snp pipeline)\n".
	"\t-r|--reference: Reference genome.\n".
	"\t-o|--output: File to output detailed information\n".
	"\t-b|--bad-positions: Bad positions file\n".
	"\t-g|--genome:  Genome file to compare to.\n".
	"\t-v|--verbose\n";
}

sub build_bad_positions
{
        my ($bad_pos_file) = @_;
	my %bad_positions;

        open(my $fh, "<$bad_pos_file") or die "Could not open $bad_pos_file: $!";

        while(my $line = readline($fh))
        {
                chomp $line;
                my ($sub_line) = ($line =~ /^([^#]*)/);
                my ($chrom,$start,$end) = split(/\t/,$sub_line);
                next if (not defined $chrom or $chrom eq '');
                next if ($start !~ /^\d+$/);
                next if ($end !~ /^\d+$/);

                # swap in case start/end are reversed
                my $real_start = ($start < $end) ? $start : $end;
                my $real_end = ($start < $end) ? $end : $start;

                for (my $i = $real_start; $i < $real_end; $i++)
                {
                        $bad_positions{"${chrom}_${i}"} = 1;
                }
        }

        close($fh);

	return \%bad_positions;
}

# MAIN
if (!GetOptions('i|input-align=s' => \$input_align,
		'r|reference=s' => \$reference,
		'b|bad-positions=s' => \$bad_positions_file,
		'o|output=s' => \$output,
		'v|verbose' => \$verbose,
		'g|genome=s' => \$genome))
{
	die "Invalid option\n".usage;
}

die "Error: no input file defined\n".usage if (not defined $input_align);
die "Error: file $input_align does not exist\n".usage if (not -e $input_align);
die "Error: no genome file defined\n".usage if (not defined $genome);
die "Error: genome=$genome does not exist\n".usage if (not -e $genome);
die "Error: reference is not defined\n".usage if (not defined $reference);
die "Error: reference=$reference does not exist\n".usage if (not -e $reference);
die "Error: no bad-positions defind" if (not defined $bad_positions_file);
die "Error: bad-positions=$bad_positions_file does not exist" if (not -e $bad_positions_file);
die "Error: no output file defined" if (not defined $output);

my $reference_base = basename($reference);
my $genome_base = basename($genome);
my $bad_positions_base = basename($bad_positions_file);

$keep_temp = 0 if ($verbose);

my $genomes_core_snp = generate_core_genome_snps($input_align, $genome);

my $genome_name = determine_genome_name($genomes_core_snp,$genome);
die "error: no entry in table $input_align for $genome" if (not defined $genome_name);

my $bad_positions = build_bad_positions($bad_positions_file);

my $pipeline_set = build_pipeline_set($genome_name, $genomes_core_snp);
my ($nucmer_set,$nucmer_set_no_bad_pos) = parse_genome_nucmer($genome,$reference, $genomes_core_snp, $genome_name, $bad_positions);

# compare sets of snps
my $intersection = $pipeline_set * $nucmer_set;
my $uniq_pipeline = $pipeline_set - $nucmer_set;
my $uniq_nucmer = $nucmer_set - $pipeline_set;

my $intersection_no_bad_pos = $pipeline_set * $nucmer_set_no_bad_pos;
my $uniq_pipeline_no_bad = $pipeline_set - $nucmer_set_no_bad_pos;
my $uniq_nucmer_no_bad = $nucmer_set_no_bad_pos - $pipeline_set;

my $total_bases_filtered = scalar(keys %$bad_positions);
my $total_bases_reference = get_reference_length($reference);
my $total_bases_kept = $total_bases_reference - $total_bases_filtered;

print "Reference\tGenome\tBad Positions\tTotal Reference Length\tTotal Length Kept\t% Kept\tCore Pipeline Positions\tNucmer Positions\tNucmer Filtered Positions\tIntersection\tUnique Core Pipeline\tUnique Nucmer\t% True Positive\t% False Positive\t% False Negative\n";
print "$reference_base\t$genome_base\t$bad_positions_base\t$total_bases_reference\t$total_bases_kept\t";
printf "%0.1f\t",($total_bases_kept/$total_bases_reference)*100;
print $pipeline_set->size."\t".$nucmer_set->size."\t".$nucmer_set_no_bad_pos->size."\t".
	$intersection_no_bad_pos->size."\t".$uniq_pipeline_no_bad->size."\t".$uniq_nucmer_no_bad->size."\t";

my $true_positive;
my $false_positive;
my $false_negative;
if ($nucmer_set_no_bad_pos->size > 0)
{
	$false_negative = sprintf "%0.1f",($uniq_nucmer_no_bad->size/$nucmer_set_no_bad_pos->size)*100;
}
else
{
	$false_negative = 'undefined';
}

if ($pipeline_set->size > 0)
{
	$false_positive = sprintf "%0.1f",($uniq_pipeline_no_bad->size/$pipeline_set->size)*100;
	$true_positive = sprintf "%0.1f",($intersection_no_bad_pos->size/$pipeline_set->size)*100;
}
else
{
	$false_positive = 'undefined';
	$true_positive = 'undefined';
}

print "$true_positive\t$false_positive\t$false_negative\n";

open(my $oh, ">$output") or die "Could not open file $output for writing: $!";
print $oh "Working on $input_align\n";
print $oh "Working with bad positions $bad_positions_file\n";
print $oh "Working with genome $genome\n";
print $oh "Working with reference $reference\n\n";

print $oh "Intersection\t".$intersection_no_bad_pos->size."\n";
print $oh "Contig\tPosition\t$reference_base\t$genome_base\n";
for my $e (sort $intersection_no_bad_pos->elements)
{
	print $oh "$e\n";
}

print $oh "\nUnique to Nucmer\t".$uniq_nucmer_no_bad->size."\n";
print $oh "Contig\tPosition\t$reference_base\t$genome_base\n";
for my $e (sort $uniq_nucmer_no_bad->elements)
{
	print $oh "$e\n";
}

print $oh "\nUnique to Core Pipeline\t".$uniq_pipeline_no_bad->size."\n";
print $oh "Contig\tPosition\t$reference_base\t$genome_base\n";
for my $e (sort $uniq_pipeline->elements)
{
	print $oh "$e\n";
}

close($oh);
