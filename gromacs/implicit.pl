#! /usr/bin/perl -w

# NOTE: water is hardcoded as tip3p here

use strict;
sub  error_state_check (@ ); # defined at the bottom
sub make_fake_top (@);
sub fix_impl_params (@);

defined $ARGV[0] ||
    die "Usage: gromacs.pl <pdb name root>/no_protein [<list of ligand names> -remd|-min].\n";

$| = 1; # turn on autoflush;

# remd flag must be the last, for now
my $remd = 0;
($ARGV[$#ARGV] eq "-remd") && ($remd = 1);
my $minimization = 0;
($ARGV[$#ARGV] eq "-min" ) && ($minimization = 1);

##############################################################################
##############################################################################
my $np = 0;

my $write_cmd_log = 1;
my $pdb2gro;
my $gromacs_path = "/usr/local/bin";
my $perl_path    = "/home/ivanam/perlscr/gromacs";
my $mpirun       = "/usr/local/bin/mpirun";
my ($mdrun, $mdrun_mpi, $grompp);
my $gromacs_run;
my $groc;
my $genrestr; 
my $grompp_root;
my $protein = 0;
my $home = `pwd`; chomp $home;

my $hostname = `hostname`;
chomp $hostname;

  
$gromacs_run = "$gromacs_path/mdrun";
$grompp      = "$gromacs_path/grompp";
$groc        = "$perl_path/gro_concat.pl";
$pdb2gro     = "$perl_path/pdb2gro.pl";
$genrestr    = "$gromacs_path/genrestr";

if ($hostname eq "donkey") {

    $gromacs_path = "/usr/bin";
    $grompp       = "/usr/bin/grompp";
    $gromacs_run  = "/usr/bin/mdrun";
    $mdrun_mpi    = "/usr/bin/mdrun_mpi";
    $mpirun       = "/usr/bin/mpirun";

} else {
    $mdrun_mpi = "";
}

foreach ($gromacs_path,  $perl_path, $gromacs_run, $grompp, $groc, $pdb2gro, $genrestr) {
    ( -e $_ ) || die "\n$_ not found.\n\n";
}

$gromacs_run .= " -nt 1";


if ( $np && ! -e $mpirun) {
    die "\n$mpirun not found.\n\n";
}


##############################################################################
##############################################################################

my $name        = $ARGV[0]; # expect ok pdb file called $name.pdb present
my $forcefield  = "amber99sb";
my $water = "tip3p";
#my $forcefield = "oplsaa";
#my $forcefield = "gmx";
#my $box_type   = "cubic";
my $box_type    = "triclinic";
my $box_edge    =  0.7; # distance of the box edge from the molecule in nm 
my $neg_ion     = "Cl"; # theses names depend on the choice of the forcefield (check "ions.itp")
my $pos_ion     = "Na";
my $genion_solvent_code = 12;

if (  $forcefield  eq  "oplsaa" || $forcefield  eq "amber99sb" ) {
    $neg_ion  = "CL";
    $pos_ion  = "NA";
}

##############################################################################
##############################################################################
my ($in_dir, $top_dir, $em1_dir, $em2_dir,  $production) = 
    ("00_input", "01_topology", "02_em_steepest", "03_em_lbfgs", "04_production");

foreach ( $in_dir, "$in_dir/em_steep.mdp", "$in_dir/em_lbfgs.mdp",  "$in_dir/md.mdp" ) {
    ( -e $_ ) || die "\n$_ not found.\n\n";
}

if ( $name eq "no_protein") {
    $protein = 0;
    (  defined $ARGV[1] ) ||
	die "No protein, no small molecule ... what are we doing here?\n";
    $box_edge    =  2.0;
} else {
    ( -e "$in_dir/$name.pdb") || die "$in_dir/$name.pdb not found\n";
    $protein = 1;
}

#foreach ( $top_dir, $em1_dir, $em2_dir, $pr1_dir, $pr2_dir, $production) {
#    (-e $_) || `mkdir $_`;
#}

##############################################################################
##############################################################################
$write_cmd_log &&  ( open (CMD_LOG, ">cmd.log") || die "Cno cmd.log: $!.\n");


##############################################################################
##############################################################################
## check if itp and gro given for all ligands
my @ligand_names = ();
my %multiplicity = (); # how many time each ligand appears
my $mult;
my $ligand_name;
my $file;
# this nomenclature corresponds to Gromacs forcefield
my %ion = ( "K", 1, "Na",  1, "Ca", 2,  "Mg", 2, "Cl", -1, "Zn", 2,
	    "NA",  1, "CA", 2,  "MG", 2, "CL", -1, "ZN", 2, 
	    "na",  1, "ca", 2,  "mg", 2, "cl", -1, "zn", 2 );
# is this correct?
my %opls_ion_names = ( "mg", "MG2+", "ca", "CA2+",   "li", "LI+",   
		       "na", "NA+",   "k", "K+",   "rb", "Rb+",   
		       "cs", "Cs+",   "f", "F-",   "cl", "CL-",   
		       "br", "BR-",   "i", "I-");

if ( defined $ARGV[1] ) {
    my @aux;
    open ( LF, "<$in_dir/$ARGV[1]") ||
	die "Cno $in_dir/$ARGV[1]: $!.\n";
    while ( <LF> ) {
	next if (! /\S/);
	chomp;
	@aux = split;
	push @ligand_names, $aux[0];

	if ( $aux[0] ne "water" ) {
	    if ( defined  $aux[1] ) {
		$multiplicity{$aux[0]} = $aux[1];
	    } else {
		die "Number of instances of molecule $aux[0] not defined in $ARGV[1].\n";
	    }
	}
       
    }
    $protein || ($name = join "_", @ligand_names);

    close LF;
    foreach $ligand_name ( @ligand_names ) {

	for ($mult=1; $mult <= $multiplicity{$ligand_name}; $mult ++ ) {
	    my $ln = (lc $ligand_name);
	    my $name_root = $ln;
	    my $cmd;
		

	    if ( $multiplicity{$ligand_name} > 1 ) {
		$name_root = $ln.$mult;
	    }

	    $file = $name_root.".gro";
	    next if ( -e "$in_dir/$file");
	    ( -e "$in_dir/$name_root.pdb" ) || die "Cno $in_dir/$name_root.pdb: $!.\n";

	    # handle ions
	    if ( defined $ion{$ligand_name} ) {
		if (  $forcefield  eq  "oplsaa" ) {
		    my $tmp = "tmp.ion";
		    my ($ion_type, $new_ion_type, $new_line);
		    my ($serial, $res_seq, $x, $y, $z);
		    open (ION_IF, "<$in_dir/$name_root.pdb");
		    open (ION_OF, ">$top_dir/$name_root.gro");
		    while ( <ION_IF> ) {

			$ion_type = substr $_, 12, 4;  $ion_type =~ s/\s//g;
			$serial   = substr $_,  6, 5;  $serial =~ s/\s//g;
			$res_seq  = substr $_, 22, 4;  $res_seq=~ s/\s//g;
			$x = substr $_, 30, 8; $x =~ s/\s//g;
			$y = substr $_, 38, 8; $y =~ s/\s//g;
			$z = substr $_, 46, 8; $z =~ s/\s//g;
			
			(defined $opls_ion_names{lc $ion_type}) || 
			    die "opls name for  $ion_type not defined.".
			    "\n(at least not in $0).\n";
			
			$new_ion_type = sprintf "%-5s",  $opls_ion_names{lc $ion_type};
			   
			printf ION_OF  "%5d%5s%5s%5d%8.3f%8.3f%8.3f\n",
			$res_seq, $new_ion_type,  $ion_type, $serial, $x/10, $y/10, $z/10;
		    }
		    close ION_IF;
		    close ION_OF;

		} else {
		    $cmd = "$pdb2gro <  $in_dir/$name_root.pdb >  $top_dir/$name_root.gro ";
		    (system $cmd) && die "Error running $cmd\n";
		    ( $write_cmd_log ) &&  print CMD_LOG "$cmd\n";
		}

		# handle other types of ligands
	    } else {

		( -e "$in_dir/$name_root.gro") || die "$in_dir/$name_root.gro must be prepared in advance\n";
		( -e "$in_dir/$ln.itp") || die "$in_dir/$ln.itp must be prepared in advance\n";
		# check whether we have the parameters for GB, if not xi the file
		my $ret = "" || `grep implicit_genborn_params $in_dir/$ln.itp`;
		$ret || fix_impl_params ("$in_dir/$ln.itp");
	    }
	}

	if ( ! defined $ion{$ligand_name} ) { # ion "topology" is included by default
	    # all other molecules have their own gro and itp files
	    $file = lc $ligand_name.".itp"; 
	    ( -e "$in_dir/$file") || die "$in_dir/$file not found in ".`pwd`;

	    # check whether we have the parameters for GB, if not xi the file
	    my $ret = "" || `grep implicit_genborn_params $in_dir/$file`;
	    $ret || fix_impl_params ("$in_dir/$file");
	}
	
    } 
} 

############################################################################## 
##############################################################################
my $command;
my $ret;
my $program;
my @aux;
my $charge;
my $input_system_for_md;
my $log;

###############
# process pdb into gro and topology files
###############

chdir $home;
(-e  $top_dir) || `mkdir $top_dir`;
chdir $top_dir;

if ( ! -e "$name.top" || ! -e "$name.gro" )  {

    if ( $protein ) {
	$program = "$gromacs_path/pdb2gmx";
	$log = "pdb2gmx.log";
	print "\t runnning $program \n";
	# -ignh instructs pdb2gmx to ingore H and place its own
	$command  = "$program  -ignh -ff $forcefield -water none  -f ../$in_dir/$name.pdb -o $name.gro -p $name.top ";
	( -e "pdb2gmx_in") && ( `rm pdb2gmx_in`); 
	if ( -e "ssbridges" ) {
	    # ssbridges has one "y\n" for each ssbridge (sequentailly
	    # by the first cysteine) that we want to maintain
	    # I guess "n\n" for the ones we do not want too
	    `cat ssbridges > pdb2gmx_in`;
	    $command  .= " -ss";
	} 

	if ( -e "termini" ) {
	    # termini has the following format: "2\n2\n" for each chain 
	    # (4 x 2 for two chains and so on) 
	    `cat termini >> pdb2gmx_in`;
	    $command  .= " -ter";
	}
	
	( -e "pdb2gmx_in") && ($command  .= " < pdb2gmx_in");
	$command  .= " > $log 2>&1";
	($write_cmd_log)  &&  print CMD_LOG "$command\n";

	(system $command)
	    && die "Error:\n$command\nerror"; # looks like it exits with something on success
	error_state_check ( $log, ("masses will be determined based on residue and atom names"));

	( -e "pdb2gmx_in") && `rm pdb2gmx_in`;
    }

    if ( @ligand_names ) {
	my $written;
	`cp ../$in_dir/*gro ../$in_dir/*.itp .`; # too messy otherwise
	####################################
	# concatenate gro files
	if ( ! $protein && @ligand_names == 1 ) {
	    ( -e "$name.gro" ) || die "$name.gro not found\n";

	} else {
	    if ( $protein ) {
		`cp $name.gro $name.orig.gro`;
		$command = "$groc  $name.gro ";
	    } else  {
		$command = "$groc ";
	    }
	    foreach $ligand_name ( @ligand_names ) {
		if ($ligand_name eq "water") {
		    $command .=  $ligand_name.".gro ";
		    next;
		}
		if ( $multiplicity{$ligand_name} == 1 ) {
		    $command .=  (lc $ligand_name).".gro ";
		} else {
		    for ($mult=1; $mult <= $multiplicity{$ligand_name}; $mult ++ ) {
			$command .=  (lc $ligand_name).$mult.".gro ";
		    }
		}
	    }
	    $command .= " > tmp";
	    my $ret;
	    $ret = system $command ;
	    $ret	&& die "Error:\n$command\n$ret"; 
	    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
	    `mv tmp $name.gro`;
	}

	####################################
	# change the topology (*.top) file
	if ( ! $protein ) {
	    make_fake_top ($name);
	}
	open ( TOP, "<$name.top") ||
	    die "Error opening $name.top: $!.\n";

	open ( OF, ">tmp") ||
	    die "Error opening tmp output file: $!.\n";
	$written = 0;
	while ( <TOP> ) {
	    print OF;
	    if ( !$written && /^\#include/ ) {
		foreach $ligand_name ( @ligand_names ) {
		    next if  ($ligand_name eq "water");
		    next if ( defined $ion{$ligand_name} );
		    print OF "#include \"$home/$top_dir/". lc $ligand_name.".itp\"\n";
		}
		$written = 1;
	    } elsif ( /^\[ molecules \]/ ) {
		while ( <TOP> ) {
		    if ( /\S/ ) {
			print OF;
		    }
		}
		foreach $ligand_name ( @ligand_names ) { 
		    if  ($ligand_name eq "water"){
			print OF "SOL     $multiplicity{$ligand_name}\n";
		    } else { 
			if ( $forcefield eq "oplsaa" && defined $opls_ion_names{lc $ligand_name} ) {
			    print OF  $opls_ion_names{lc $ligand_name}. "  $multiplicity{$ligand_name}\n";
			} else {
			    print OF  $ligand_name."     $multiplicity{$ligand_name}\n";
			}
		    }
		}
		print OF "\n";
	    }
	}
	close OF;
	close TOP;
	`mv tmp $name.top`;

	
    }

} else {
    print "\t gro and top files found\n";
}



###############
# place the sytem in a box - we don't need it but I'm too lazy to change the script
###############
$file = "$name.box.gro";
if (!  -e  $file) {
    $program = "$gromacs_path/editconf";
    $log = "editconf.log";
    print "\t runnning $program \n";
    $command = "$program -f $name.gro -o $file  -bt $box_type -d $box_edge -c > $log  2>&1";
    # -c is the centering command
    (system $command)
	&& die "Error running\n$command\n"; 
    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    # some bug in editconf: if the box triclinic it reports "no boxtype spcified,
    # but constructs something which has all three unit cell vectors perpendicular 
    # and of different lengths
    error_state_check ( $log, ("masses will be determined based on residue and atom names",
				    "No boxtype specified"));
} else {
    print "\t $file found\n"; 
}

############################################################################## 
##############################################################################


###############
# geometry "minimization"
###############
# preprocessing  = making of  tpr file

chdir $home;
(-e $em1_dir) || `mkdir $em1_dir`;
chdir $em1_dir;

$file = "$name.em_input.tpr";
if (!  -e  $file) {

    # grompping
    # -c is the centering command
    my $ion_name;
    $program = "$grompp";
    $log     = "grompp.log";
    print "\t runnning $program \n";
    $command = "$program -f ../$in_dir/em_steep.mdp -c ../$top_dir/$name.box.gro ".
	"-p ../$top_dir/$name.top -o $file ";
    ( -e "../$in_dir/groups.ndx" ) && ($command .=  " -n ../$in_dir/groups.ndx ");
    $command 	.= "> $log  2>&1";
    ($write_cmd_log ) &&  print CMD_LOG "$command\n";
    system $command 
	|| die "Error:\n$command\nerror";  # if no charge, we are done


    $charge = 0;
    $ret = `grep \'System has non-zero total charge\' $log`;
    if ( $ret ) {
	@aux = split " ", $ret;
	$charge = int ( sprintf "%5.0f", pop @aux ) ;
	print "\t charge $charge\n"; 
       ( $charge ) && print "\t system has nonzero charge - should be taken care of by the impl solvent\n";
    }    
 
    $input_system_for_md = "$name.box.gro";
    
    
} else { 
    print "\t $file found\n"; 
} 


# minimization - round 1
$file = "$name.em_out.gro";
if (!  -e  $file) {
    #
    $program = "$gromacs_run";
    $log = "energy_minimization.log";
    print "\t runnning $program -- steepest descent energy minimization \n";
    $command = "$program -s $name.em_input.tpr -c $name.em_out.gro -o $name.em_out.trr > $log  2>&1";
    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    (system $command)
	&& die "Error:\n$command\nerror"; 
    error_state_check ( "$log", ("masses will be determined based on residue and atom names"));
    $ret = `grep \'Steepest Descents converged\' $log`;
    if ( ! $ret ) {
	print "$program did not converge. Please check the file called $log.\n";
	#exit (1);
    }
    #`rm  $name.em_out.trr`;
  
} else {
    print "\t $file found\n"; 
}



# minimization - round 2
# will have to dom some re-grompping, though
chdir $home;
(-e $em2_dir) || `mkdir $em2_dir`;
chdir $em2_dir;

$file = "$name.em_input.tpr";
if (! -e  $file) {

    #grompp again
    $log = "grompp.log";
    $program = "$grompp";
    print "\t runnning $program \n";
    $command = "$program -f ../$in_dir/em_lbfgs.mdp  -c ../$em1_dir/$name.em_out.gro  ".
	"  -p ../$top_dir/$name.top -o $name.em_input.tpr  -maxwarn 1 ";
    ( -e "../$in_dir/groups.ndx" ) && ($command .=  " -n ../$in_dir/groups.ndx ");
    $command 	.= "> $log  2>&1";
   ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    (system $command) 
	&& die "Error:\n$command\nerror"; 
     error_state_check ("$log", 
			("maxwarn", "defaults to zero instead of generating an error"));
} else {
    print "\t $file found\n"; 
}

$file = "$name.em_out.gro";
if (!  -e  $file) {
    #
    $program = "$gromacs_run";
    $log = "energy_minimization.log";
    print "\t runnning $program -- lbfgs energy minimization \n";
    $command = "$program -s $name.em_input.tpr -c $name.em_out.gro -o $name.em_out.trr > $log  2>&1";
    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    (system $command)
	&& die "Error:\n$command\nerror"; 
    error_state_check ( "$log", ("masses will be determined based on residue and atom names"));
    $ret = `grep \'Low-Memory BFGS Minimizer converged\' $log`;
    if ( ! $ret ) {
	print "$program did not converge. Please check the file called $log.\n";
	#exit (1);
    }
    #`rm  $name.em_out.trr`;
} else {
    print "\t $file found\n"; 
}


$minimization && exit;


############################################################################## 
##############################################################################


###############
# ... and finally ... the production run!
###############

chdir $home;
(-e $production) || `mkdir $production`;
chdir $production;


# preprocessing
$file = "$name.md.tpr";
if (!  -e  $file) {


    if ( $protein ) {
	# there are some horror stories with the protein unfolding under implicit waters
	# so restrain the the backbone (posres.itp file):
	$program = "$genrestr";
	print "\t runnning $program \n";
	$command = "echo 4 | $program  -f ../$em2_dir/$name.em_out.gro > /dev/null 2>&1 ";
	( $write_cmd_log ) &&  print CMD_LOG "$command\n";
	(system $command) 
	    && die "Error:\n$command\n"; 
    }


    # grompp
    $program = "$grompp";
    $log  = "grompp_before_production_run.log";
    print "\t runnning $program \n";
    # -DPOSRES in mdp file will  instruct grompp to look for posres.itp file
    $command = "$program  -f  ../00_input/md.mdp -c ../$em2_dir/$name.em_out.gro  ".
	" -p ../$top_dir/$name.top -o $file -maxwarn 1 ";
    ( -e "../$in_dir/groups.ndx" ) && ($command .=  " -n ../$in_dir/groups.ndx ");
    $command 	.= "> $log  2>&1";
    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    (system $command) 
	&& die "Error:\n$command\n"; 
    error_state_check ( "$log", ("maxwarn", 
				    "defaults to zero instead of generating an error"));
} else {
    print "\t $file found\n"; 
}


# md 
$file = "$name.md.edr";
if (!  -e  $file) {
    $program = "$gromacs_run";
    $log  = "production_run.log";
    print "\t runnning $program --  md  simulation proper\n";
    $command = "$program -s $name.md.tpr -o $name.md.trr -c $name.md.gro ".
	"  -e $file > $log  2>&1";
    #
    ( $write_cmd_log ) &&  print CMD_LOG "$command\n";
    (system $command) 
	&& die "Error:\n$command\n"; 
   error_state_check ( "$log", ("maxwarn"));
} else {
    print "\t $file found\n"; 
}


###############
#  compress the trajectory, strip hydrogens and gzip
###############

=pod
$command = "$gromacs_path/trjconv -f  $name.md.trr -o $name.md.xtc";
system $command 
	|| die "Error:\n$command\nerror";
`rm $name.md.trr`;


$command = "echo 0 | $gromacs_path/trjconv -s $name.md.tpr -f $name.md.xtc -o tmp.pdb ";
system $command 
	|| die "Error:\n$command\nerror";

$command = "  awk -F\ '\' \'\$14 != \"H\"\' tmp.pdb >  trajectory.pdb";
system $command 
	|| die "Error:\n$command\nerror";

if ($np) {
    $command = " gzip  trajectory.pdb";
    system $command 
	|| die "Error:\n$command\nerror";
}
`rm tmp.pdb`;
=cut



#################################################################################

###############
# extending the run
###############

#tpbconv -f old_name.trr -s old_name.tpr -e old_name.edr -o new_name.tpr -until <time in ps>
#mdrun -v -deffnm new_name -s new_name.tpr


#################################################################################
#################################################################################
sub  error_state_check (@ ) {

    my $logfile = shift @_;
    my @tolerated_warnings = @_;
    my $ret;
    my @lines;
    my $serious;
    my $line;

    
    $ret = `grep -i error $logfile | grep -v gcq`; # the retarded quote may have the word error in it
    if ( $ret ) {
	$serious = "";
	@lines = split "\n", $ret;
	foreach $line ( @lines ) {
	    if ( grep  {$line =~ $_ } @tolerated_warnings) {
	    } else {
		$serious = $line;
		last;
	    }
	}
	if ( $serious ) {
 	    print "$program ended in error state. Please check the file called $logfile.\n";
	    print "$serious\n\n";
	    exit (1);
	}
    }

    $ret = `grep -i warning $logfile`;
 
    if ( $ret ) {
	$serious = "";
	@lines = split "\n", $ret;
	foreach $line ( @lines ) {
	    if ( grep  {$line =~ $_ } @tolerated_warnings) {
	    } else {
		$serious = $line;
		last;
	    }
	}
	if ( $serious ) {
 	    #print "$program issued a warning. Please check the file called $logfile.\n";
	    #print "$serious\n\n";
	    #exit (1);
	}
   }
 


}



sub make_fake_top (@){

    my $name = shift @_;

    open (FAKE, ">$name.top") ||
	die "Cno $name.top:$!\n";
    
    print FAKE "; topology wrapper written by $0.\n";
    print FAKE "; Include forcefield parameters\n";
    print FAKE "#include  \"$forcefield.ff/forcefield.itp\n";

    print FAKE "; Include Position restraint file\n";
    print FAKE "#ifdef POSRES\n";
    print FAKE "#include \"posre.itp\"\n";
    print FAKE "#endif\n";

    print FAKE "; Include water topology\n";
    print FAKE "#include \"$forcefield.ff/$water.itp\"\n";

    print FAKE "#ifdef POSRES_WATER\n";
    print FAKE "; Position restraint for each water oxygen\n";
    print FAKE "[ position_restraints ]\n";
    print FAKE ";  i funct       fcx        fcy        fcz\n";
    print FAKE "   1    1       1000       1000       1000\n";
    print FAKE "#endif\n";

    print FAKE "; Include topology for ions\n";
    print FAKE "#include \"$forcefield.ff/ions.itp\"\n";

    print FAKE "[ system ]\n";
    print FAKE "; Name\n";
    print FAKE "Protein in water\n";

    print FAKE "[ molecules ]\n";
    print FAKE "; Compound        #mols\n";

    close FAKE;

}



############################################################################## 
##############################################################################
sub fix_impl_params (@){

    print "*^^^^^TOOL^****************\n";


    ($forcefield  eq "amber99sb") 
	|| die "GB params assumes  amber99sb forcefield ...\n";
 
    my $itpfile = $_[0];
    my %params = ();


    $params{"C"} = "         0.172    1      1.554    0.1875    0.72 ; C ";
    $params{"CA"} = "            0.18     1      1.037    0.1875    0.72 ; C";
    $params{"CB"} = "            0.172    0.012  1.554    0.1875    0.72 ; C";
    $params{"CC"} = "            0.172    1      1.554    0.1875    0.72 ; C";
    $params{"CN"} = "           0.172    0.012  1.554    0.1875    0.72 ; C";
    $params{"CR"} = "           0.18     1      1.073    0.1875    0.72 ; C";
    $params{"CT"} = "           0.18     1      1.276    0.190     0.72 ; C";
    $params{"CV"} = "           0.18     1      1.073    0.1875    0.72 ; C ";
    $params{"CW"} = "           0.18     1      1.073    0.1875    0.72 ; C";
    $params{"C*"} = "           0.172    0.012  1.554    0.1875    0.72 ; C";
    $params{"H"} = "            0.1      1      1        0.115     0.85 ; H";
    $params{"HC"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"H1"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"HA"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"H4"} = "           0.1      1      1        0.115     0.85 ; H";
    $params{"H5"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"HO"} = "           0.1      1      1        0.105     0.85 ; H";
    $params{"HS"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"HP"} = "           0.1      1      1        0.125     0.85 ; H";
    $params{"N"} = "            0.155    1      1.028    0.17063   0.79 ; N";
    $params{"NA"} = "           0.155    1      1.028    0.17063   0.79 ; N";
    $params{"NB"} = "           0.155    1      1.215    0.17063   0.79 ; N";
    $params{"N2"} = "           0.16     1      1.215    0.17063   0.79 ; N";
    $params{"N3"} = "           0.16     1      1.215    0.1625    0.79 ; N";
    $params{"O"} = "            0.15     1      0.926    0.148     0.85 ; O";
    $params{"OH"} = "           0.152    1      1.080    0.1535    0.85 ; O";
    $params{"O2"} = "           0.17     1      0.922    0.148     0.85 ; O";
    $params{"S"} = "            0.18     1      1.121    0.1775    0.96 ; S";
    $params{"SH"} = "           0.18     1      1.121    0.1775    0.96 ; S";

    
    `cp $itpfile $itpfile.orig`;
    my @lines = split "\n", `cat $itpfile.orig`;
    my $new_itp = "";
    my $reading = 0;

   
    foreach my $line (@lines) {
	if ( $line =~ /atomtype/ ) {
	    $reading = 1;
	} elsif ( $reading && $line =~ /\[/ ) {
	    
	    # add the hacked gb field;
	    print $new_itp;exit;

	    $reading = 0;

	}

	($reading )  && ( $new_itp .= $line."\n");

    }


    print $new_itp;

    exit;


    return;
}