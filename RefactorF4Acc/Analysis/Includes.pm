package RefactorF4Acc::Analysis::Includes;

use RefactorF4Acc::Config;
use RefactorF4Acc::Utils;
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

use RefactorF4Acc::Parser qw( parse_fortran_src );

use Exporter;

@RefactorF4Acc::Analysis::Includes::ISA = qw(Exporter);

@RefactorF4Acc::Analysis::Includes::EXPORT_OK = qw(
    &find_root_for_includes    
);


sub find_root_for_includes {
    ( my $stref, my $f ) = @_;
    
    $stref = _create_include_chains( $stref, 0 );  # assumes we start at node 0 in the tree
    for my $inc ( keys %{ $stref->{'IncludeFiles'} } ) {
#       print "INC: $inc\n";
#       print Dumper($stref->{'IncludeFiles'}{$inc});
        if ($stref->{'IncludeFiles'}{$inc}{'Status'}==$UNREAD) {
        	#WV23JUL2012: This is weak, clearly the only good way is to find the includes in rec descent 
            croak "TROUBLE: $inc (in $f) not yet parsed, how come?";
#            print "WARNING: $inc not yet parsed, parsing ...\n";
#                $stref->{'IncludeFiles'}{$inc}{'Root'}      = $f;
                $stref->{'IncludeFiles'}{$inc}{'HasBlocks'} = 0;
                $stref = parse_fortran_src( $inc, $stref );   
#                print Dumper($stref->{'IncludeFiles'}{$inc});         
        }
        if ( $stref->{'IncludeFiles'}{$inc}{'InclType'} eq 'Common' ) {
#            print "FINDING ROOT FOR $inc ($f)\n" ;
            $stref = _find_root_for_include( $stref, $inc, $f );
            print "ROOT for $inc is "
              . $stref->{'IncludeFiles'}{$inc}{'Root'} . "\n"
              if $V 
        }
    }
    return $stref;
}    # END of find_root_for_includes()

# -----------------------------------------------------------------------------
=pod

`_find_root_for_include()` is called for every include file in IncludeFiles, after `_create_include_chains()` has created all the chains; 
by 'chain' we mean a path in the call tree where every node contains the include for its child nodes.
The purpose of this routine is to prune the paths, i.e. remove includes from nodes that don't need them.
The algorithm is as follows: 
- compare Includes with CommonIncludes.
    - if an inc is only in CommonIncludes, it is inherited
    - the node needs to keep it either
        - it has more than one child node
        - it contains a call to a refactored subroutine which contains the include  
    - any other case, just remove the include
=cut
sub _find_root_for_include {
    ( my $stref, my $inc, my $sub ) = @_;
    
    my $Ssub = $stref->{'Subroutines'}{$sub};
    
    if ( exists $Ssub->{'Includes'}{$inc} ) {
        # Not inherited
        $stref->{'IncludeFiles'}{$inc}{'Root'} = $sub;
    } else {
        # Inherited 
        # $sub is (currently) not 'Root' for $inc
        my $nchildren   = 0;
        my $singlechild = '';
        for my $calledsub ( keys %{ $Ssub->{'CalledSubs'} } ) {
            if (
                exists $stref->{'Subroutines'}{$calledsub}{'CommonIncludes'}
                {$inc} )
            {
                $nchildren++;
                $singlechild = $calledsub;
            }
        }

        if ( $nchildren == 0 ) {
            die
"_find_root_for_include(): Can't find $inc in parent or any children, something's wrong!\n";
        } elsif ( $nchildren == 1 and $Ssub->{'RefactorGlobals'}==0) {

            #           print "DESCEND into $singlechild\n";
            delete $Ssub->{'CommonIncludes'}{$inc};
            _find_root_for_include( $stref, $inc, $singlechild );
#       } elsif ($Ssub->{'RefactorGlobals'}==2) {
#           # The current node must be Root for this $inc. Exit the search.
#               die '$Ssub->{RefactorGlobals}==2 for '.$inc;
                    
        } else {
            
            # head node is root
            #           print "Found $nchildren children with $inc\n";
            $stref->{'IncludeFiles'}{$inc}{'Root'} = $sub;
        }
    }
    return $stref;
}    # END of _find_root_for_include()

# -----------------------------------------------------------------------------
# What we do is simply a recursive descent until we hit the include and we log that path
# Then we prune the paths until they differ, that's the root
# We also need to add the include to all nodes in the divergent paths
sub _create_include_chains {
    ( my $stref, my $nid ) = @_;

    if ( exists $stref->{'Nodes'}{$nid}{'Children'}
        and @{ $stref->{'Nodes'}{$nid}{'Children'} } )
    {
        # Find all children of $nid
        my @children = @{ $stref->{'Nodes'}{$nid}{'Children'} };

# Now for each of these children, find their children until the leaf nodes are reached
        for my $child (@children) {
            $stref = _create_include_chains( $stref, $child );
        }
    } else {
# We reached a leaf node
#       print "Reached leaf $nid\n";
# Now we work our way back up via the parent using a separate recursive function
        $stref = __merge_includes( $stref, $nid, $nid, '' );

# The chain is identified by the name of the leaf child
# Check if the chain contains the $inc on the way up
# Note that we can check this for every inc so we need to do this only once if we're clever -- looks like the coffee is working!

        # When all leaf nodes have been processed, we should do the following:
        # Create a list of all chains for each $inc
        # Now find the deepest common node.
    }

    return $stref;
}    # END of _create_include_chains()

# -----------------------------------------------------------------------------
# From each leaf node we follow the path back to the root of the tree
# We combine all includes of all child nodes of a node, and the node's own includes, into CommonIncludes

sub __merge_includes {
    ( my $stref, my $nid, my $cnid, my $chain ) = @_;

    #   print "__merge_includes $nid $cnid ";
    # In $c
    # If there are includes with common blocks, merge them into CommonIncludes
    # We should only do this for subs that need refactoring
    my $pnid = $stref->{'Nodes'}{$nid}{'Parent'};   
    my $sub  = $stref->{'Nodes'}{$nid}{'Subroutine'};
    
    my $Ssub = $stref->{'Subroutines'}{$sub};
#    print "__merge_includes: $sub\n";
    my $f=$stref->{'Nodes'}{$pnid}{'Subroutine'};
    if ($V) {
        if ($sub ne $f ) {
            if ($Ssub->{'RefactorGlobals'}>0) {
           $chain .="$sub -> ";
            }
        } else {
            $chain=~s/....$//;
            print "$chain\n" if $chain=~/->/;
        }
    } # $V
#    if ($Ssub->{'RefactorGlobals'}>0) {
    if ( exists $Ssub->{'Includes'}
        and not exists $Ssub->{'CommonIncludes'}     
        )
    {
        for my $inc ( keys %{ $Ssub->{'Includes'} } ) {
            if ( $stref->{'IncludeFiles'}{$inc}{'InclType'} eq 'Common'
                and not exists $Ssub->{'CommonIncludes'}{$inc} )
            {
#            	print "CommonIncludes[1] ($sub) $inc\n";
                $Ssub->{'CommonIncludes'}{$inc} = 1;
            }
        }
    }
#    $stref->{'Subroutines'}{$sub}=$Ssub ;
#   print "NEED TO REFACTOR $sub, CREATE CHAIN\n";
#    } else {
#       print "NO NEED TO REFACTOR $sub, STOP CHAIN\n";
#    }
    if ( $nid != $cnid ) {
        my $csub  = $stref->{'Nodes'}{$cnid}{'Subroutine'};
        my $Scsub = $stref->{'Subroutines'}{$csub};
        if ( exists $Scsub->{'CommonIncludes'} ) {
            for my $inc ( keys %{ $Scsub->{'CommonIncludes'} } ) {
                if ( not exists $Ssub->{'CommonIncludes'}{$inc} ) {
#                    print "CommonIncludes[2] ($sub) $inc\n";	
                    $Ssub->{'CommonIncludes'}{$inc} = 1;
                }
            }
        }
    }
    die 'No subroutine name ' if $sub eq '' or not defined $sub;
    $stref->{'Subroutines'}{$sub}=$Ssub ;
    if ( $nid != 0 ) {
        $stref = __merge_includes( $stref, $pnid, $nid,$chain );
    }

    return $stref;
}    # END of __merge_includes

# -----------------------------------------------------------------------------
# I'm making this too complicated: it is enough to simply put all parameter declarations in the order we found them 
# between includes and other declarations. 
# So what we need is indeed the OrderedList of parameters, and we create them one by one in the same order; 
# then we filter any parameters in the other declarations and skip if they are empty
