#!/usr/bin/perl
use 5.012;
use warnings::unused;
use warnings;
use warnings FATAL => qw(uninitialized);
use strict;
use Data::Dumper;
$Data::Dumper::Indent = 0;
$Data::Dumper::Terse = 1;

use RefactorF4Acc::Config;
use RefactorF4Acc::Utils;
use RefactorF4Acc::State qw( init_state );
use RefactorF4Acc::Inventory qw( find_subroutines_functions_and_includes );
use RefactorF4Acc::Parser qw( parse_fortran_src );
use RefactorF4Acc::CallGraph qw( create_call_graph );
use RefactorF4Acc::Analysis qw( analyse_all );
use RefactorF4Acc::Refactoring qw( refactor_all );
use RefactorF4Acc::Emitter qw( emit_all );
use RefactorF4Acc::OpenCLTranslation qw( translate_to_OpenCL);
#use RefactorF4Acc::Builder qw( create_build_script build_executable );

use Getopt::Std;

our $usage = "
    $0 [-hwvicC] <subroutine name(s) for translation to OpenCL> <header file with macro definitions>
    Typical use: $0 -c ./rf4a.cfg -v -i main   
    -h: help
    -w: show warnings 
    -v: verbose (implies -w)
    -i: show info messages
    -c <cfg file name>: use this cfg file (default is ~/.rf4a)
    -C: Only generate call tree, don't refactor or emit
    \n";

&main();

# -----------------------------------------------------------------------------

sub main {
	(my $subname, my $build) = parse_args();
	#  Initialise the global state.
	my $stateref = init_state($subname);    
	# Find all subroutines in the source code tree
	$stateref = find_subroutines_functions_and_includes($stateref);

    # Parse the source
	$stateref = parse_fortran_src( $subname, $stateref );
     
	if ( $call_tree_only and not $ARGV[1] ) {
		create_call_graph($stateref,$subname);
		exit(0);
	}
    
    # Analyse the source
	$stateref = analyse_all($stateref,$subname);
    # Refactor the source
	$stateref = refactor_all($stateref,$subname);
   print '=' x 80, "\n";
#   map {say Dumper($_->[1]) } @{ $stateref->{'Subroutines'}{'press'}{'AnnLines'} };
   $stateref = translate_to_OpenCL($stateref,$subname);
    


#	create_build_script($stateref);
#	if ($build) {
#		build_executable();
#	}
	exit(0);

}    # END of main()
# -----------------------------------------------------------------------------
sub parse_args {
 	# Argument parsing. Factor out!
	if ( not @ARGV ) {
		die "Please specifiy FORTRAN subroutine or program to refactor\n";
	}
	my %opts = ();
	getopts( 'vwihgc:CNB', \%opts );
	
	my $help = ( $opts{'h'} ) ? 1 : 0;
    if ($help) {
        die $usage;
    }
	
	my $cfgrc= $ENV{HOME}.'/.rf4a';
    if (-e './rf4a.cfg') {
        $cfgrc='./rf4a.cfg';
    }
    if ($opts{'c'}) {
         $cfgrc= $opts{'c'} ;
    } 
	read_config($cfgrc);
	
	my $subname = $ARGV[0];
	if ($subname) {
		$subname =~ s/\.f(?:90)?$//;
	} elsif (exists $Config{'TOP'}) {
		$subname = $Config{'TOP'};
	} else {
		die "No default for toplevel subroutine (TOP) in rf4a.cfg, please specify the toplevel subroutine on command line\n"; 
	}
    
    if ( exists $Config{'NEWSRCPATH'}) {
        $targetdir =  $Config{'NEWSRCPATH'};
    }   
    
	$V = ( $opts{'v'} ) ? 1 : 0;
	$I = ( $opts{'i'} or $V ) ? 1 : 0;
	$W = ( $opts{'w'} or $V ) ? 1 : 0;
	$refactor_toplevel_globals=( $opts{'g'} ) ? 1 : 0;
	if ( $opts{'C'} ) {
		$call_tree_only = 1;
		$main_tree = $ARGV[1] ? 0 : 1;

	}
	$noop = ( $opts{'N'} ) ? 0 : 1;

	my $build = ( $opts{'B'} ) ? 1 : 0;

	return ($subname,$build);
}

=head1 SYNOPSIS

Run the script with -G and read the generated PDF documentation (i.e. all portions of POD inside 'markdown' tags).

=head1 OVERVIEW

=head1 TODOs

* Subroutine args marked as InOut can actually be In if the value is never used. We should check that!
"Never used" means that we have to check against all calls to the subroutine. 
As I am interested in factored-out routines, I will focus on single-call routines.
- If an argument is marked as InOut 
    - if the actual value is an expression, set to In
    - if the actual value is a local variable and it is not read after the call to the subroutine, set to In
        This is more complicated: 
        1. determine it's a local variable, i.e. not in the caller argument list. OK
        2. look if it occurs after the call to the subroutine => need to parse all lines

* Remap scalar arguments into arrays to have fewer arguments to pass -> mostly done, but not complete
What is needed is not just a merge for scalars, but also for arrays    

* Deal with OFRTRAN's arcane KIND approach 
  
*  Declarations from F2C-ACC are broken, emit our own => OK

*  But F2C-ACC's function calls are wrong too! They use the non-pointer vars where they should use the pointers! => OK

*  Put F2C-ACC into our tree, if the license allows it. => OK

=begin markdown

# FORTRAN Refactoring Tool |$VER|

\copyright  Wim Vanderbauwhede, 2010-2012 

## SYNOPSIS

    |$usage|
    
## DESCRIPTION

The purpose of this tool is to refactor FORTRAN code by automatically performing the following transformations:

- Replace all `common` block variables by subroutine arguments.
- Factor out marked blocks of code into subroutines
- Resolve name conflicts between parameters, local variables and function arguments
- Rewrite label-based loops into DO-loops
- Normalise the code to lowercase and 6-spaces based layout
    
Furthermore, the tool preforms a number of operations intended to facilitate translation to C:

* Replace `continue` statements by calls to a no-op routine
* Analyse which `goto`'s can be replaced by `break` statements in C
* Analyse the IO direction and type of all subroutine arguments
     
It is designed to work on large FORTRAN programs, split over multiple files, written in a mixture of FORTRAN 77 and FORTRAN 95.        

## DESIGN

Because the aim of the tool is to refactor the source code, and not to translate or compile it, we don't use a full grammar-based lexer and parser but instead we perform context-free parsing using regular expressions. As in many cases we require the context to analyse the parsed data, the program maintains a global state with the following structure:

    State
        Top -- Toplevel sub name 
        Nodes -- A node represents a call to a subroutine or function. 
                 For each node ID, store ID of parent & children and the sub name
        NId -- Current node ID, for traversal
        CallTree -- The call tree as a list of indented strings. #TODO make more generic and add a pretty-printer
        Indents -- used during traversal for counting the indentation level
        Subroutines -- A map with for subroutine name, following entries:
            Source -- Source file name for the subroutine
            AnnLines -- The source per line, split lines have been merged, with information about each line            
            Blocks -- Blocks marked for refactoring into subroutines
            HasBlocks -- Boolean: does this sub contain blocks?
    *       Args -- subroutine arguments
            Includes -- This is a map { name => index }, used as a set 
    *       Vars -- all declared variables. 
            Parameters
            CalledSubs -- Another map-used-as-set of all subs called in the sub  
            Status -- UNREAD,READ,PARSED,FROM_BLOCK,C_SOURCE
    *       Globals -- For every include, a list of its /common/ vars used in the sub             
    *       CommonIncludes -- A set of includes that contain /common/ vars
    *       Commons -- Like Globals, but for every var it has Type, Kind, Shape, IODir
    *       HasCommons -- Boolean, if TRUE we need to refactor /common/ vars         
            ConflictingParams -- List of parameters that conflict with global variables 
            StringConsts -- String constants are replaced by placeholders 
                            and stored in this map
            Gotos -- Set of labels for which a 'goto' exists
    *       Program -- Boolean, if TRUE this sub is a program
            Called -- Boolean, if TRUE this sub is called in other subs 
    *       RefactoredArgIODirs -- IO dir for every refactored arg #TODO: make this RefactoredArgs -> IODirs, List, ...
    *       RefactoredArgList -- List of all refactored args 
            RefactoredCode -- refactored source, line by line, long lines are split
        Functions -- Same as Subroutines, but for Functions #TODO: maybe we could simply have a flag "IsFunction" in Subroutines?
            Source            
            AnnLines  
            Vars          
            Parameters
            [Blocks]
            HasBlocks            
            Includes            
            CalledSubs
            Status      
            StringConsts
            [Gotos]
            Called
            RefactoredCode      
        IncludeFiles -- Similar as Subroutines/Functions but for Includes
            Source
            AnnLines            
            Vars            
            Parameters
            Status            
    *       Type -- Common or Parameter
    *       Root -- highest subroutine in the call tree for every include
            Commons 
    *       ConflictingGlobals -- List of global variables that conflict with other vars or params
            RefactoredCode
        BuildSources    

### Refactoring 'common' variables into subroutine arguments

FORTRAN's `common` blocks are a mechanism to create global variables:

"The COMMON statement defines a block of main memory storage so that
different program units can share the same data without using arguments." [F77 ref]

This is problematic for translation of code to OpenCL as of course it is not possible to have
globals across memory spaces. 
(Also, I personally think these globals are /evil/ -- as the FLEXPART codebase shows repeatedly:
e.g. PI is defined in one place as a parameter and in another place as a common variable, which is only assigned
in a deeply nested subroutine.) 

### Codebase Inventory 

To refactor 'common' variables into subroutine arguments requires first of all an analysis of the full codebase. 
Therefore, the first step is to determine which files in a directory are used by the main program. 
To do so we first create an inventory of all subroutines, functions and include files in the codebase, 
and then we perform a dependency analysis and build the call tree.    
The inventory is done by finding all FORTRAN source files (using `File::Find`, and looking in them 
for subroutine, function and program signatures and include statements.

### Dependency Analysis and Call Tree
 
Next, we perform a recursive descent on the main program, descending in all subroutine and function calls.

=end markdown



## Draft Outline  

0.2 Get rid of "common" variables, move them into function arguments 
This is refactoring, and there is really only one proper way to do this:
- parse the FORTRAN source in a labeled-block-aware way
- check which variables from the common block are used
- put them in the function signature
- for variables declared outside the block in question, find the ones that are used within the block
and add them to the function signature as well

Now, I don't have a full FORTRAN parser, but let's see what we can do with some limiting assumptions:
- assume the block is simply identified with a comment "C BEGIN blockname" and "C END blockname"
- assume any line starting with `/^\s[\+\&]/` is a continuation line, deal with these first
- assume that _all_ variables in includecom are common, and _all_ variable in includepar are parameters?
That won't do. No, we read the includes, and parse the "common" blocks
- we're only really interested in a few specific intrinsic types: 

    /(integer|real|double\s+precision|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/ 

The most difficult bit is finding the variables, I guess `$varname` should do?

With these assumptions, we can write a crude parser and function arg identifier as follows:
0. Slurp the source; strip the comments
1. Join up the continuation lines (maybe split lines with ; )
2. Parse the type declarations in the source, create a table %vars
3. Parse includes, recursively doing 0/1/2
4. For includes, parse common blocks, create %commons
5. Split the source based on the block markers
6. Identify which vars are used
    - in both => these become function arguments
    - only in "outer" => do nothing for those
    - only in "inner" => can be removed from outer variable declarations
7. Identify which commons are used in inner, make them function arguments

Not necessarily in this order:
8. When encountering a CALL, recurse and resolve globals (but only that)
9. When encountering a  function call, idem; although I'd prefer it if functions would be pure!
10. F2C-ACC is a bit buggy, so help it a bit: identify which CONTINUE statements are actually END DO
and replace them accordingly; for the other CONTINUE statements, it might be better to 
ensure that instead of CONTINUE, they do nothing in a different way. 
The only reliable way I found is to replace the continue with call noop, where noop is a subroutine that does nothing

How do we replace the args in a subroutine call?

- Find a subroutine call
- first check if we now about it by looking in a list of subroutine calls => We use 'IsSub'
- if we know it, it means we have resolved the globals, the list should be added to the node;
then just add the globals to the call
- otherwise, add the index in the list of source lines to a hash of subs 
- in fact, this can be a hash of "anythings", i.e.
 
        $stref->{'Nodes'}{$filename}{'SubroutineCall'}{$name}={'Pos'=>[$index,...],'Globals'=>[],...};
    
    As this is a "global", I need to pass it around between calls.
- recurse and figure out globals used. also, store the signature in the node hash
- add the globals to the end of the signature, and emit the new code.
- it would be nice to emit the code in a hash 

        $refactored_sources{$filename}=\@lines;
    
- return the list of all the globals to be added to the call
- update the call in %refactored_sources

        'Subroutines' => { 
                    $name => {
                       'Source' => $src,
                       'Lines' =>[$line],
                       'Blocks'=>{},
                       'HasBlocks'=>0|1                       
                       'Vars'=>
                       'RefactoredCode' => {},    
                       'Status' => 0|1|2|3,
                       'Info' => [ {
                            'Signature' => {'Name' => ..., 'Args' => ...},
                            'Include' => {'Name' => ...,}
                            'ExGlobVarDecls'=> ...
                            'SubroutineCall'=>{'Name' => ..., 'Args' => ...}
                            'VarDecl' => [...]
                       } ],        
                     }
        }

Status: for programs, subroutines, functions and includes 
    0: after find_subroutines_functions_and_includes() 
    1: after read_fortran_src()
    2: after parse_fortran_src_OLD()
    3: after create_subroutine_source_from_block()
After building this structure, what we need is to go through it an revert it so it becomes index => information



In Haskell, I guess we'd have a type representing all fields rather than a map:

State = MkState {
        subroutines::Subroutines
    ,   nid::Int
    ,   nodes::Nodes
    ,   includes::Includes
    ,   functions::Functions
    ,   calltree::CallTree
    ,

}

Nodes = Hash.Map Int Node

=cut

