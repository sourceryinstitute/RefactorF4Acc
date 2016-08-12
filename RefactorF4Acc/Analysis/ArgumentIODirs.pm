package RefactorF4Acc::Analysis::ArgumentIODirs;
use v5.16;

use RefactorF4Acc::Config;
use RefactorF4Acc::Utils
  qw( get_maybe_args_globs type_via_implicits in_nested_set );
use RefactorF4Acc::Refactoring::Common
  qw( get_annotated_sourcelines stateful_pass emit_f95_var_decl get_f95_var_decl );
use RefactorF4Acc::Refactoring::Subroutines::Signatures
  qw( refactor_subroutine_signature );
use RefactorF4Acc::Refactoring::Subroutines::Calls
  qw( refactor_subroutine_call_args);

#
#   (c) 2010-2012 Wim Vanderbauwhede <wim@dcs.gla.ac.uk>
#

use vars qw( $VERSION );
$VERSION = "1.0.0";

use warnings::unused;
use warnings;
use warnings FATAL => qw(uninitialized);
use strict;
use Carp;
use Data::Dumper;
use Storable qw( dclone );

use Exporter;

@RefactorF4Acc::Analysis::ArgumentIODirs::ISA = qw(Exporter);

@RefactorF4Acc::Analysis::ArgumentIODirs::EXPORT_OK = qw(
  &determine_argument_io_direction_rec
  &update_argument_io_direction_all_subs
  &type_via_implicits
  &conditional_assignment_fsm
);

# -----------------------------------------------------------------------------
# We do a recusive descent for all called subroutines, and for the leaves we do the analysis
sub determine_argument_io_direction_rec {
	( my $f, my $stref ) = @_;
	my $c;
	if ($V) {
		$c = ( defined $stref->{Counter} ) ? $stref->{Counter} : 0;
		print "\t" x $c, $f, "\n";
	}

	my $Sf = $stref->{'Subroutines'}{$f};

	if ( exists $Sf->{'CalledSubs'}{'List'}
		and scalar @{ $Sf->{'CalledSubs'}{'List'} } > 0 )
	{
		for my $calledsub ( @{ $Sf->{'CalledSubs'}{'List'} } ) {
			$stref->{Counter}++ if $V;

			$stref = determine_argument_io_direction_rec( $calledsub, $stref );

			$stref->{Counter}-- if $V;
		}

		#   die "Resolved IO for called subs, now use it!\n" if $f =~ /advance/;
		print "\t" x $c, "--------\n" if $V;
		$stref = _determine_argument_io_direction_core( $stref, $f );

		# We come here for LES and all is well?

	} else {

#	say  "\t" x $c; print "LEAF $f";
# For a leaf, this should resolve all
# For a non-leaf, we should merge the declarations from the calls
# This is more tricky than it seems because a sub can be called multiple times with different arguments.
# So first we need to determine the argument of the call, then map them to the arguments of the sub
		$stref = _determine_argument_io_direction_core( $stref, $f );
	}

	return $stref;
}    # determine_argument_io_direction_rec()

# -----------------------------------------------------------------------------
sub _determine_argument_io_direction_core {
	( my $stref, my $f ) = @_;
	if ( exists $stref->{'Subroutines'}{$f} ) {
		my $Sf = $stref->{'Subroutines'}{$f};

		print "DETERMINE IO DIR FOR SUB $f\n" if $V;

		# Then for each of these, we go through the args.
		# If an arg has a non-'U' value, we overwrite it.
		# Up to here RefactoredArgs does not contain any parameter decls
		$stref = _analyse_src_for_iodirs( $stref, $f );
	}
	return $stref;
}    # _determine_argument_io_direction_core()

# -----------------------------------------------------------------------------
# To determine if a subroutine argument is I, O or IO:
# if it appears only on the LHS of an '=' => O
# if does not appear on the LHS of an '=' => I
# otherwise => IO
# So start by setting them all to 'I'
# so, look for '=' and split in LHS/RHS

# -----------------------------------------------------------------------------
# This function works on RHS variables, i.e. variables being read
# The rules are
# Read =>
#   Unknown => In
#   Out => InOut
# Write =>
#   Out

#Access mode of the pointer-type subroutine arguments
#
#* Describe every argument with a tuple (IODir,AccessState) where
#
#IODir = Unknown | In | Out | InOut | Unused
#
#AccessState = Unaccessed | Read | Written
#
#* The initial argument state is set to (Unknown,Unaccessed).
#
#* If an argument is read from and never written to, its IO direction is In:
#
#Unknown & Read =>  In
#

#* If an argument is written to before it is read from, its IO direction is Out.
#
#Unknown & Write =>  Out
#

#* If an argument is read from and later written to, its IO direction is InOut.
#
#In & Write =>  InOut
#

#* If an argument was not used in the subroutine body, set the status to Unused:
#
#Unknown =>  Unused

sub _set_iodir_read {
	( my $mvar, my $args_ref ) = @_;

	#    if ( $args_ref->{$mvar}{'IODir'} eq 'Out' ) {
	#        print "FOUND InOut ARG $mvar\n" if $V;
	#        $args_ref->{$mvar}{'IODir'} = 'InOut';
	#    } els
	#    say Dumper($args_ref->{$mvar});
	if (   not exists $args_ref->{$mvar}{'IODir'}
		or not defined $args_ref->{$mvar}{'IODir'} )
	{
		$args_ref->{$mvar}{'IODir'} = 'Unknown';
	}
	if ( $args_ref->{$mvar}{'IODir'} eq 'Unknown' ) {
		print "FOUND In ARG $mvar\n" if $DBG;
		$args_ref->{$mvar}{'IODir'} = 'In';
	}
	return $args_ref;
}

sub _set_iodir_write {
	( my $mvar, my $args_ref ) = @_;
	if ( exists $args_ref->{$mvar}
		and ref( $args_ref->{$mvar} ) eq 'HASH' )
	{
		if ( exists $args_ref->{$mvar}{'IODir'}
			and defined $args_ref->{$mvar}{'IODir'} )
		{
			if ( $args_ref->{$mvar}{'IODir'} eq 'In' ) {
				print "FOUND InOut ARG $mvar\n" if $DBG;
				$args_ref->{$mvar}{'IODir'} = 'InOut';
			} elsif ( $args_ref->{$mvar}{'IODir'} eq 'Unknown' ) {
				print "FOUND In ARG $mvar\n" if $DBG;
				$args_ref->{$mvar}{'IODir'} = 'Out';
			}
		} else {
			$args_ref->{$mvar}{'IODir'} = 'Unknown';
		}
	}
	return $args_ref;
}

sub _set_iodir_read_write {
	( my $mvar, my $args_ref ) = @_;
	if ( exists $args_ref->{$mvar}
		and ref( $args_ref->{$mvar} ) eq 'HASH' )
	{
		if ( exists $args_ref->{$mvar}{'IODir'} ) {
			print "FOUND InOut ARG $mvar\n" if $DBG;
			$args_ref->{$mvar}{'IODir'} = 'InOut';
		}
	}
	return $args_ref;
}

# -----------------------------------------------------------------------------
sub _find_vars_w_iodir {
	( my $line, my $args_ref, my $subref ) = @_;

# So we just split this in chunks, which means we ignore any arrays or function calls!
	my @chunks = split( /\W+/, $line );

	for my $mvar (@chunks) {
		next if $mvar eq '';
		next if $mvar =~ /^\d+$/;
		next if $mvar =~ /^(\-?(?:\d+|\d*\.\d*)(?:e[\-\+]?\d+)?)$/;
		next if $mvar =~ /\b(?:if|then|do|goto|integer|real|call|\d+)\b/;
		if ( exists $args_ref->{$mvar} and ref( $args_ref->{$mvar} ) eq 'HASH' )
		{

			if ( exists $args_ref->{$mvar}{'IODir'} ) {
				$args_ref = $subref->( $mvar, $args_ref );
			}
		}    #else {
		     # Just means that this is not an argument!
		     #}
	}
	return $args_ref;
}    # END of _find_vars_w_iodir()

# -----------------------------------------------------------------------------
# Purely for clarity, maybe this routine should take the arguments as arguments?
# What we want in this routine is determine IO dirs for leaves and look them up for non-leaves
sub _analyse_src_for_iodirs {
	( my $stref, my $f ) = @_;

	#    local $W=1;local $V=1;

	print "_analyse_src_for_iodirs() $f\n" if $V;
	my $Sf = $stref->{'Subroutines'}{$f};

	if ( not exists $Sf->{'IODirInfo'} or $Sf->{'IODirInfo'} == 0 ) {
		if ( not exists $Sf->{'HasRefactoredArgs'}
			or $Sf->{'HasRefactoredArgs'} == 0 )
		{
			say "SUB $f DOES NOT HAVE RefactoredArgs";
			croak 'BOOM! ' . __LINE__ . ' ' . $f . ' : ' . Dumper($Sf);
		}
		my $args = dclone( $Sf->{'RefactoredArgs'}{'Set'} );
		if ( exists $Sf->{'Function'} and $Sf->{'Function'} == 1 ) {			
			# Don't touch
			# Why not? even a Function can have Intents other than In!
			# FIXME!
			say "INFO: SKIPPING IODir analysis for FUNCTION $f" if $I;
		} else {
			my $annlines = get_annotated_sourcelines( $stref, $f );

			for my $index ( 0 .. scalar( @{$annlines} ) - 1 ) {
				my $line = $annlines->[$index][0];
				my $info = $annlines->[$index][1];
				
				# TDDO: use $info
				if ( $line =~ /^\s*\!/ ) {
					next;
				}

				# Skip format statements
				# TDDO: use $info
				if (   $line =~ /^\s+format/
					or $line =~ /^\d+\s+format/ )
				{
					next;
				}

				# Skip the signature
				if ( exists $info->{'Signature'} ) {
					next;
				}

				# Skip any 'use' or 'include' lines
				if ( exists $info->{'Use'} or exists $info->{'Include'} ) {
					next;
				}

				# Skip the declarations
				if ( exists $info->{'VarDecl'} ) { next; }

				if ( exists $info->{'Do'} ) {
					my $mvar = $info->{'Do'}{'Iterator'};
					if ( exists $args->{$mvar}
						and ref( $args->{$mvar} ) eq 'HASH' )
					{
						if ( exists $args->{$mvar}{'IODir'} ) {
							$args = _set_iodir_write( $mvar, $args );
						}
					}
					for my $mvar ( @{ $info->{'Do'}{'Range'}{'Vars'} } ) {
						if ( exists $args->{$mvar}
							and ref( $args->{$mvar} ) eq 'HASH' )
						{
							if ( exists $args->{$mvar}{'IODir'} ) {
								$args = _set_iodir_read( $mvar, $args );
							}
						}
					}
					next;
				}

				# File open statements
				# TDDO: use $info
				if (   $line =~ /^\s+open\s*\(\s*(.+)$/
					or $line =~ /^\d+\s+open\s*\(\s*(.+)$/ )
				{
					my $str = $1;
					$args =
					  _find_vars_w_iodir( $str, $args, \&_set_iodir_read );
					next;
				}

				if (   exists $info->{'WriteCall'}
					or exists $info->{'PrintCall'} )
				{

					# All variables are read from, so IODir is read
					for my $mvar (
						@{ $info->{'CallArgs'}{'List'} },
						@{ $info->{'ExprVars'}{'List'} },
						@{ $info->{'CallAttrs'}{'List'} }
					  )
					{
						if ( exists $args->{$mvar}
							and ref( $args->{$mvar} ) eq 'HASH' )
						{
							if ( exists $args->{$mvar}{'IODir'} ) {
								$args = _set_iodir_read( $mvar, $args );
							}
						}
					}
					next;
				}

				if ( exists $info->{'ReadCall'} or exists $info->{'InquireCall'}) {

				  # Arguments are written to, so IODir is write; others are read
				  #				carp Dumper($info);
					for my $mvar ( @{ $info->{'CallArgs'}{'List'} } ) {

						#				 	croak if $mvar eq 'fghold';
						if ( exists $args->{$mvar}
							and ref( $args->{$mvar} ) eq 'HASH' )
						{
							if ( exists $args->{$mvar}{'IODir'} ) {
								$args = _set_iodir_write( $mvar, $args );
							}
						}
					}
					for my $mvar (
						@{ $info->{'ExprVars'}{'List'} },
						@{ $info->{'CallAttrs'}{'List'} }
					  )
					{
						if ( exists $args->{$mvar}
							and ref( $args->{$mvar} ) eq 'HASH' )
						{
							if ( exists $args->{$mvar}{'IODir'} ) {
								$args = _set_iodir_read( $mvar, $args );
							}
						}
					}
					next;
				}

				# Subroutine call
				if (   exists $info->{'SubroutineCall'}
					&& exists $info->{'SubroutineCall'}{'Name'} )
				{
					my $name = $info->{'SubroutineCall'}{'Name'};

# So we get the IODir for every arg in the call to the subroutine
# We need both the original args from the call and the ex-glob args
# It might be convenient to have both in $info; otoh we can get ExGlobArgs from the main table
#croak Dumper($info->{'ExprVars'}{'List'}) if scalar @{ $info->{'ExprVars'}{'List'} } >3; 
					for my $mvar ( @{$info->{'ExprVars'}{'List'}} ) {
						# So these var can be local, global or even intrinsics. 
						# Check if they are global first.
						if ( exists $args->{$mvar} and ref( $args->{$mvar} ) eq 'HASH' ) {
							if ( exists $args->{$mvar}{'IODir'} ) {
									$args = _set_iodir_read( $mvar, $args );
								}
						}
					}
					my $iodirs_from_call = _get_iodirs_from_subcall( $stref, $f, $info );

#				croak "DEAL WITH MULTIPLE OCCURRENCES: $f => $name => ".Dumper($iodirs_from_call) if $name eq 'reorder_ncwrfout_1realfield' and exists  $iodirs_from_call->{'vardata'};
					for my $var ( keys %{$iodirs_from_call} ) {
# Damn Perl! exists $args->{$var}{'IODir'} creates the entry for $var if it did not exist!

						if ( exists $args->{$var}
							and ref( $args->{$var} ) eq 'HASH' )
						{
							if ( exists $args->{$var}{'IODir'} ) {

								if ( $iodirs_from_call->{$var} eq 'In' ) {
									if ( not defined $args->{$var}{'IODir'}
										or $args->{$var}{'IODir'} eq 'Unknown' )
									{
										$args->{$var}{'IODir'} = 'In';
									} elsif ( $args->{$var}{'IODir'} eq 'Out' )
									{

	   # if the parent arg is Out and the child arg is In, parent arg stays Out!
										$args->{$var}{'IODir'} = 'Out';
									} # if it's already In or InOut, it stays like it is.
								} elsif ( $iodirs_from_call->{$var} eq 'InOut' )
								{
									if ( $args->{$var}{'IODir'} eq 'Unknown' ) {
										$args->{$var}{'IODir'} = 'InOut';
									} elsif ( $args->{$var}{'IODir'} eq 'Out' )
									{
										$args->{$var}{'IODir'} = 'Out';
									} elsif ( $args->{$var}{'IODir'} eq 'In' ) {
										$args->{$var}{'IODir'} = 'InOut';
									}    # if it is In, it stays In
								} elsif ( $iodirs_from_call->{$var} eq 'Out' ) {

									if ( $args->{$var}{'IODir'} eq 'Unknown' ) {
										$args->{$var}{'IODir'} = 'Out';
									} elsif ( $args->{$var}{'IODir'} eq 'In' ) {
										$args->{$var}{'IODir'} = 'InOut';
									} # if it's already InOut or Out, stays like it is.
								} else {
									print
"WARNING: IO direction for $var in call to $name in $f is Unknown\n"
									  if $W;
								}
							} else {
								print "WARNING: $f: NO IODir info for $var\n"
								  if $W;
							}
						} else {
							if (exists $iodirs_from_call->{$var} and defined $iodirs_from_call->{$var}) {
							print "INFO: $f: $var is not an argument, ignoring IODir " . $iodirs_from_call->{$var} . "\n" if $I;
							} else {
								say "INFO: $f: $var is not in \$iodirs_from_call" if $I;
							}
						}

	 #                    else {
	 #                               print "$var is LOCAL".$iodirs->{$var}."\n";
	 #                    }

						# So at this point, $args has correct IODir information
					}
					# TODO: use $info
					if ( $line =~ /^\s*if\s*\((.+)\)\s+call\s+/ ) {
						my $cond = $1;
						$cond =~ s/[\(\)]+//g;
						$cond =~
						  s/\.(eq|ne|gt|ge|lt|le|and|or|not|eqv|neqv)\./ /;
						die $line unless defined $cond;
						$args = _find_vars_w_iodir( $cond, $args, \&_set_iodir_read );
					}
					next;
				}    # SubroutineCall

# Encounter Assignment
# WV20150304 TODO: factor this out and export it so we can use it as a parser for assignments
# TODO: use $info
				if (
					    $line =~ /[\w\s\)]=[\w\s\(\+\-\.\'\"]/
					and $line !~ /^\s*do\s+.+\s*=/
					and $line !~ /\bparameter\b/
					and $line !~ /read|write|print/    # for implicit DO
				  )
				{
 
					# FIXME: if (...) open|write is not covered
					my $tline = $line;
					$tline =~ s/^\s*\d+//;             # Labels
					$tline =~ s/^\s+//;
					$tline =~ s/\s+$//;
					$tline =~ s/[<=>][<=>]/<>/g;

					# FIXME: This is still weak!
					my $var = '';
					my $rhs = '';

					# First check if this is a single-line if statement
					if ( $tline =~ /^if\b/ ) {

# split on
# space or closing paren
# word
# 0 or 1 occurences of parentheses without '=' inside them
# the '=' sign
#*so in other words, if it's an array assignment
# FIXME: If the LHS is an array assignment we are not checking the index for its IO dir
						if ( $tline !~ /(open|write|read|print|close)\s*\(/ ) {
							( my $cond, $var, my $sep, $rhs ) =
							  conditional_assignment_fsm($tline);
							$args = _find_vars_w_iodir( $cond, $args,
								\&_set_iodir_read );
							if ( $sep ne '' ) {
								die $line unless defined $sep;
								$args = _find_vars_w_iodir( $sep, $args,
									\&_set_iodir_read );
							}
						} elsif ( $tline =~ /read\s*\(/ ) {
							croak
"WARNING: IGNORING conditional read call <$tline>";

							next;
						} elsif ( $tline =~ /print.+?,/ ) {
							croak
"WARNING: IGNORING conditional print call <$tline>";
							next;
						} else {
							( my $cond, my $call, $rhs ) =
							  split( /(open|write)/, $tline );

						   #                      print $tline,"\n";
						   #                      print "$cond ? $call $expr\n";
							die $line unless defined $cond;
							$args = _find_vars_w_iodir( $cond, $args,
								\&_set_iodir_read );
						}
					} else {

						if ( $tline =~ /(open|close)\s*\(/ ) {
							my $call = $1;

							say
"WARNING: IGNORING conditional $call <$tline> (_analyse_src_for_iodirs) "
							  . __LINE__
							  if $W;

						 #            	 		warn "IGNORING $call call <$tline>\n";
							next;
						} elsif ( $tline =~ /(write|read|print)\s*\(/ ) {
							my $call = $1;
							croak "THIS IS NEVER REACHED";
							croak
"WARNING: IGNORING conditional $call <$tline> (_analyse_src_for_iodirs) "
							  . __LINE__;

						 #            	 		warn "IGNORING $call call <$tline>\n";
							next;

						} else {
#							croak $tline if $tline=~/dx/;
							( $var, $rhs ) = split( /\s*=\s*/, $tline );
							if ( $var =~ /\(/ ) {
								# Must be an array assignment
								$var =~ s/\s*\((.+)\)$//;
								my $str = $1;
								if ( not defined $str ) {
									print "WARNING: IGNORING <$tline>, CAN'T HANDLE IT (_analyse_src_for_iodirs)\n" if $W;
								} else {
									$args = _find_vars_w_iodir( $str, $args,
										\&_set_iodir_read );
								}
							}
						}
					}

					# First check the RHS for In
					die "_analyse_src_for_iodirs(): RHS not defined inf $f: $line\n" unless defined $rhs;

					# So anything on the RHS is "In", this is OK
					$args = _find_vars_w_iodir( $rhs, $args, \&_set_iodir_read );
					if ( exists $args->{$var} ) {
						$args = _set_iodir_write( $var, $args );
					}
#					croak Dumper($args) if $tline=~/dx/;
				} else {    # not an assignment, do as before

				  #                say "NON-ASSIGNMENT LINE: $line in $f" if $V;

					_find_vars_w_iodir( $line, $args, \&_set_iodir_read );
				}

			}
		}
		for my $arg ( keys %{$args} ) {
			
			if (
				exists $stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}
				{$arg} )
			{
				if ($args->{$arg} != 1) {
				$stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$arg} =
				  { %{ $args->{$arg} } };
				} else {
					my $decl = get_f95_var_decl($stref, $f, $arg);
#					say "DECL:".Dumper($decl);
					$stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$arg} = $decl;
				}

			}
		}

		# Here for some reason corr has been added as an argument!
		$Sf->{'IODirInfo'} = 1;
	}    # if IODirInfo had not been set to 1
	return $stref;
}    # END of _analyse_src_for_iodirs()

# -----------------------------------------------------------------------------

#stronger:
#- we replaced <=> by <>
#- so split on \s*=\s* => RHS
#- remove if\s*
#( ... )\s*...
#
#This we should parse with an FSM, counting the parens,
#so we get
#
#COND=(...)
#
#\s*LHS

sub conditional_assignment_fsm {
	( my $line ) = @_;
	my (
		$do_nothing,    # 0
		$read_cond,     # 1
		$store_cond,    # 2
		$read_lhs,      # 3
		$store_lhs,     # 4
		$read_sep,
		$store_sep,
		$read_rhs,      # 5
		$store_rhs,     # 6
	) = 0 .. 8;

	my $cond = '';
	my $lhs  = '';
	my $sep  = '';
	my $rhs  = '';

	my @cs         = split( '', $line );
	my $ncs        = scalar @cs;
	my $cct        = 0;
	my $st         = $do_nothing;
	my $nest_count = 0;
	for my $c (@cs) {
		next if $c eq ' ';
		$cct++;

#### The transitions are:

		if ( $st == $do_nothing ) {
			if ( $c eq '(' ) {
				$st = $read_cond;
			}
		} elsif ( $st == $read_cond ) {
			if ( $c eq '(' ) {
				$nest_count++;
			} elsif ( $c eq ')' ) {
				if ( $nest_count == 0 ) {

					# store condition, or enter state
					$st = $store_cond;
				} else {
					$nest_count--;
				}
			}
		} elsif ( $st == $store_cond ) {
			$st = $read_lhs;
		} elsif ( $st == $read_lhs ) {
			if ( $c eq '(' ) {
				$st = $read_sep;
			} elsif ( $c eq '=' ) {
				$st = $store_lhs;
			}
		} elsif ( $st == $read_sep ) {
			if ( $c eq '=' ) {
				$st = $store_sep;
			}
		} elsif ( $st == $store_sep ) {
			$st = $read_rhs;
		} elsif ( $st == $store_lhs ) {
			$st = $read_rhs;
		} elsif ( $st == $read_rhs ) {
			if ( $cct == $ncs ) {
				$st = $store_rhs;
			}
		}

##### The actions are:
		if    ( $st == $read_cond ) { $cond .= $c }
		elsif ( $st == $read_lhs )  { $lhs  .= $c }
		elsif ( $st == $read_sep )  { $sep  .= $c }
		elsif ( $st == $read_rhs ) {
			$rhs .= $c;
		}
	}

	#    print "if(| $cond  |) [| $lhs |] = [| $rhs |]\n";
	return ( $cond, $lhs, $sep, $rhs );
}    # END of conditional_assignment_fsm

# ----------------------------------------------------------------------------------------------------
# So we get the IODir for every arg in the call to the subroutine
# We need both the original args from the call and the ex-glob args
# It might be convenient to have both in $info; otoh we can get ExGlobArgs from the main table
#                my $iodirs_from_call = _get_iodirs_from_subcall( $stref, $f, $info );

# So what we do is:
# 1. get all vars from the ArgMap table.
# Note that some args are expressions, in which case they are used read-only per definition, so their IODir will always be In
# For the non-expression args, we need to use the table and then look up the IODir from the OrigArgs but via get_var_record_from_set($Sf,'OrigArgs')

# 2. If the ArgMap table is empty that means the sub was originally called without arguments.
# In that case, the arguments of the called sub are the same as of its signature.
# So the IODirs are those of the RefactoredArgs of $name
# 3. We can of course have both, the originals followed by the refactored ones.
sub _get_iodirs_from_subcall {
	( my $stref, my $f, my $info ) = @_;

	my $name              = $info->{'SubroutineCall'}{'Name'};
	my $called_arg_iodirs = {};
	if ( not exists $stref->{'ExternalSubroutines'}{$name} ) {

		# This is the parent
		my $Sf = $stref->{'Subroutines'}{$f};
#croak 'FIXME: must add ExprVars as well, but they are all intent(In)';
		# These are the refactored arguments of the parent
		my $args   = $Sf->{'RefactoredArgs'}{'Set'};
		my $argmap = $info->{'SubroutineCall'}{'ArgMap'};

		#		croak Dumper($info->{'CallArgs'}) if $name eq 'interpol_all';
		my $Sname = $stref->{'Subroutines'}{$name};

		#		my $i     = 0;

		# For every argument of the ORIGINAL called subroutine
		for my $sig_arg ( keys %{$argmap} ) {

# See if there is a corresponding argument in the signature of the called subroutine
			my $call_arg = $argmap->{$sig_arg};

# The $call_arg can be Array, Scalar, Sub, Expr or Const
# Only if it is Array or Scalar  does it need to be considered for writing to by the subroutine
# We need to check the other variables in Array, Sub and Expr but they cannot be anything else than read-only

			my $call_arg_type = $info->{'CallArgs'}{'Set'}{$call_arg}{'Type'};

			if ( $call_arg_type eq 'Scalar' or $call_arg_type eq 'Array' ) {

				# This means that $call_arg is an argument of the caller $f
				# That is what interests us as we want the IODir in that case

				if ( $call_arg_type eq 'Array' ) {
					$call_arg = $info->{'CallArgs'}{'Set'}{$call_arg}{'Arg'};
				}

				if (    exists $args->{$call_arg}
					and exists $Sname->{'RefactoredArgs'}{'Set'}{$sig_arg} )
				{    # this caller argument has a record in RefactoredArgs of $f
					   # look up the IO direction for the corresponding $sig_arg
					my $sig_iodir = $Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}{'IODir'};
					if ( not exists $called_arg_iodirs->{$call_arg} ) {
						$called_arg_iodirs->{$call_arg} = $sig_iodir;
					} else {
						if (
							(
								    $called_arg_iodirs->{$call_arg} eq 'In'
								and $sig_iodir eq 'Out'
							)
							or (    $called_arg_iodirs->{$call_arg} eq 'Out'
								and $sig_iodir eq 'In' )
						  )
						{
							$called_arg_iodirs->{$call_arg} = 'InOut';
						}
					}
				} else {

		  # Of course called args can be local variables or parameters.
		  # In the case of Parameters, we can set the called sub's sig arg to In

					# It could be that this call arg is a parameter, let's check
					# But to do so I should include Parameters in Vars
					# Basically, they can be LocalParam and InclParam
					# In that way we can look them up in the nested sets
					if ( in_nested_set( $Sf, 'Parameters', $call_arg ) ) {
						say
"CALLER ARG <$call_arg> for call to $name in $f IS A PARAMETER."
						  if $DBG;
#						if (    
#						scalar keys %{ $Sname->{'Callers'} } == 1
#							and $Sname->{'Callers'}{$f} == 1
#							and
#							$Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}{'IODir'}
#							ne 'In' )
#						{

say "WARNING: Setting intent(In) for argument $sig_arg of $name because the called argument is a parameter!" if $W;
							print
"INFO: $name in $f is called only once; $sig_arg is a parameter, setting IODir to 'In'\n"
							  if $I;
							$Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}
							  {'IODir'} = 'In';
#						}
					} else {

# If it's a var, we don't do anything I guess? But suppose a var is being written to, and then an arg is being assigned to this var
# A var must always be written to anyway or it would be undefined.
						if ( in_nested_set( $Sf, 'Vars', $call_arg ) ) {
							say
"CALLER ARG <$call_arg> for call to $name in $f IS A LOCAL VAR."
							  if $DBG;
						} else {
							say
"CALLER ARG <$call_arg> for call to $name HAS NO REC in Vars($f): "
							  . Dumper( $Sf->{'Vars'} );    # . '<>'

			  #						  	. Dumper( $Sname->{'RefactoredArgs'}{'Set'}{$sig_arg} );
			  #						say Dumper( $Sf->{'Vars'} );
							croak;
						}
					}

					#					croak;
				}
			} else {  # If it is a Const or Expr or Sub,  the sig_arg must be In
				 # Before 20160513, this had "and there is only a single subroutine call in the code" but that is not correct
				 # It leads to Error: Non-variable expression in variable definition context (actual argument to INTENT = OUT/INOUT) at (1)
#				carp "FIXME: DOING THIS BREAKS CODE!";
				say "WARNING: Setting intent(In) for argument $sig_arg of $name because the called argument is not a variable!" if $W; 
				$Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}{'IODir'} = 'In';

#				if (    scalar keys %{ $Sname->{'Callers'} } == 1
#						and $Sname->{'Callers'}{$f} == 1
#						and $Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}{'IODir'}
#						ne 'In' )
#					{
#						print
#"INFO: $name in $f is called only once; $sig_arg is a numeric constant or expression, setting IODir to 'In'\n"
#						  if $I;
#						$Sname->{'RefactoredArgs'}{'Set'}{$sig_arg}{'IODir'} = 'In';
#					}
			}
		}

# For the refactored args that were not original args, we just copy the IODir
# So we take all refactored args but exclude the args in the argmap
# Somehow we also get the sig args when we do that, so I should exclude these as well I guess
		for my $ref_arg ( keys %{ $Sname->{'RefactoredArgs'}{'Set'} } ) {
			if ( exists $called_arg_iodirs->{$ref_arg} ) {
				say "INFO: SKIPPING $ref_arg in $f, already DONE: "
				  . $called_arg_iodirs->{$ref_arg}
				  if $called_arg_iodirs->{$ref_arg} eq 'Unknown' and $I;
				next;
			}
			if ( exists $argmap->{$ref_arg} ) {
				say "INFO: SKIPPING $ref_arg in $f, is ORIG SIG ARG (call arg: "
				  . $argmap->{$ref_arg} . ')'
				  if
					$I; # if $called_arg_iodirs->{$ref_arg} eq 'Unknown' and $I;
				next;
			}
			$called_arg_iodirs->{$ref_arg} = $Sname->{'RefactoredArgs'}{'Set'}{$ref_arg}{'IODir'};
#			  say "REF ARG: $ref_arg RECORD: ".Dumper($Sname->{'RefactoredArgs'}{'Set'}{$ref_arg});
			  if (exists $called_arg_iodirs->{$ref_arg} and defined $called_arg_iodirs->{$ref_arg}) {
#			  	say '<'.$called_arg_iodirs->{$ref_arg}.'>';
				say "INFO: IODir is Unknown for $ref_arg in $f" if $called_arg_iodirs->{$ref_arg} eq 'Unknown' and $I;
			  } else {
			  		say "INFO: NO $ref_arg in %called_arg_iodirs in $f" if $I;
			  }
		}
	} else {
		for my $arg ( @{ $info->{'SubroutineCall'}{'Args'}{'List'} } ) {
			$called_arg_iodirs->{$arg} = 'InOut';
		}
	}
	return $called_arg_iodirs;
}    # END of _get_iodirs_from_subcall()

sub update_argument_io_direction_all_subs {
	( my $stref ) = @_;
	for my $f ( keys %{ $stref->{'Subroutines'} } ) {
		next if $f eq '';
		next if exists $stref->{'ExternalSubroutines'}{$f};
		next if exists $stref->{'Modules'}{$f}; # HACK! FIXME!
		next if (exists $stref->{'Subroutines'}{$f}{'Program'} and $stref->{'Subroutines'}{$f}{'Program'} == 1);
		say "UPDATE IODIR IN $f" if $DBG;
		
		$stref = _update_argument_io_direction( $stref, $f );
	}
	return $stref;
}

sub _update_argument_io_direction {
	( my $stref, my $f ) = @_;

	my $__update_decl = sub {
		( my $annline, my $state ) = @_;
		( my $line,    my $info )  = @{$annline};
		( my $stref, my $f, my $rest ) = @{$state};
		say $line.Dumper($info) if $line=~/parameter.+nx/;	
		
		if ( exists $info->{'VarDecl'} ) {
			my $varname = $info->{'VarDecl'}{'Name'};
			my $is_param=0;
			if (ref($varname) eq 'ARRAY') {
				$is_param=1;
				$varname = $varname->[0];							
			}
			if (
					exists $stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$varname} 
				){
					
#					croak "REFACTORED".Dumper($stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$varname}) if $is_param;
					my $decl =  $stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$varname};
					if (not $is_param) {
					$info->{'VarDecl'}{'IODir'} = $stref->{'Subroutines'}{$f}{'RefactoredArgs'}{'Set'}{$varname}{'IODir'};
					} else {
						$info->{'VarDecl'}{'IODir'} ='In';
						delete $decl->{'Parameter'};
						$decl->{'Name'} = $decl->{'Var'};
						delete $decl->{'Val'};
						$decl->{'IODir'}='In';
#						croak Dumper($decl);
					}
					my $rline = emit_f95_var_decl($decl );
											
                    if (exists $info->{'Skip'}) {
                    	$rline = '! '.$rline;
                    	push @{$info->{'Ann'}},'SKIP';
                    }                    
				$annline = [ $rline, $info ];
			} else {
				#				say $line;
			}
		}
		return ( $annline, $state );
	};
	my $state = [ $stref, $f, {} ];
	( $stref, $state ) = stateful_pass( $stref, $f, $__update_decl, $state,'_update_argument_io_direction() ' . __LINE__ );

	return $stref;
}
1;
