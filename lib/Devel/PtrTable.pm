package Devel::PtrTable;
#use Inline C => Config => CLEAN_AFTER_BUILD => 0, DIRECTORY => './inline_build', BUILD_NOISY => 1;

use Inline C;
use strict;
use warnings;
use threads;
use Task::Weaken;
use base qw(Exporter);

our $VERSION = 0.01;
our @EXPORT = qw(PtrTable_get PtrTable_freecopied);

my $obj;

sub CLONE_SKIP {
    my $pkg = shift;
    return if $pkg ne __PACKAGE__;
    $obj = \"OPAQUE";
    _PtrTable_init($obj);
    return 0;
}

sub CLONE {
    my $pkg = shift;
    return if $pkg ne __PACKAGE__;
    _PtrTable_make_our_table($obj);
}

sub PtrTable_get($) {
    my $memaddr = shift;
    if(!$obj) {
        warn("This is not a child thread or ptr_table has been deleted");
        return;
    }
    _PtrTable_get($obj, $memaddr);
}

sub PtrTable_freecopied() {
    if(!$obj) {
        return;
    }
    _PtrTable_freecopied($obj);
    undef $obj;
}

1;

=head1 NAME

Devel::PtrTable - Interface to perl's old-new pointer mapping for cloning

=head2 DESCRIPTION

This provides an interface to map B<memory addresses> of duplicated/cloned perl
variables between threads.

Perl duplicates each variable when a new thread is spawned, and thus the new
underlying SV object has a new memory address.

Internally, perl maintains a C<struct ptr_tbl> during cloning, which allows the
interpreter to properly copy objects, as well as keep track of which objects were
copied.

=head2 FUNCTIONS

=head3 PtrTable_get($memaddr)

Returns a reference to whatever happened to have been stored under C<$memaddr>
in the parent thread, or undef if there is no such entry.

=head3 PtrTable_freecopied()

Free the copied pointer table

=head2 GUTS

For those who might be interested, this module does the following

=over

=item 1

Using C<CLONE_SKIP> to initialize an opaque SV and magic structure with a C<MGVTBL>
including C<svt_dup>

=item 2

Inside the C<svt_dup> hook, the stash for this module is unshifted to the beginning
of the C<stashes> fields of the C<CLONE_PARAMS> argument. This ensures that no
other module will destroy the global C<PL_ptr_table> before us. This also means
that we won't be able to see any new pointers possibly added by other packages
in their C<CLONE> methods - though this is unlikely

=item 3

After the interpreter has been cloned, our C<CLONE> method is the first thing called.
In this method, we make a duplicate C<struct ptr_tbl> object, which is available
until the perl-level C<PtrTable_freecopied> is called

=back

=head2 CAVEATS

This module cannot be too smart about which entries in the pointer table are valid
SVs, which are PerlIO objects, and which are random junk. Users of this module
are expected to have a list of valid addresses to use.

Additionally, modules which may insert other entries into the pointer table during
their own C<CLONE> methods will not have those entries available to us. See L</GUTS>
for the reason

=head1 SEE ALSO

L<perlapi> and I<perl.h>

=head1 AUTHOR AND COPYRIGHT

Copyright (C) 2011 by M. Nunberg.

You may use and distribute this module under the same terms and license as Perl
itself

=cut

__DATA__
__C__

#undef NDEBUG
#include <assert.h>

static int duphook(pTHX_ MAGIC *mg, CLONE_PARAMS *param);
static MGVTBL vtbl = {
    .svt_dup = &duphook
};

static int duphook(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    /*Make sure our CLONE gets called first*/
    av_unshift(param->stashes, 1);
    HV *mystash = gv_stashpv("Devel::PtrTable", 0);
    SvREFCNT_inc(mystash);
    av_store(param->stashes, 0, (SV*)mystash);
    mg->mg_ptr = (char*)ptr_table_new();
}

void _PtrTable_init(SV *self)
{
    MAGIC *mg = sv_magicext(SvRV(self), NULL, PERL_MAGIC_ext, &vtbl, NULL, 0);
    mg->mg_flags |= MGf_DUP;
}

static inline PTR_TBL_t*
get_our_table(SV *self)
{
    MAGIC *mg;
    for(mg = mg_find(SvRV(self), PERL_MAGIC_ext);
        mg;
        mg = mg->mg_moremagic
    ) {
        if(mg->mg_virtual == &vtbl) {
            break;
        }
    }
    
    if(!mg) {
        sv_dump(self);
        die("Couldn't find our magic!");
    }
    return (PTR_TBL_t*)mg->mg_ptr;
}

void _PtrTable_make_our_table(SV *self)
{    
    PTR_TBL_t *our_table = get_our_table(self);
    assert(PL_ptr_table);
    UV max = PL_ptr_table->tbl_max;
    UV i = 0;
    PTR_TBL_ENT_t *head_ent;
    for(i = 0; i <= max; i++) {
        for(head_ent = PL_ptr_table->tbl_ary[i];
            head_ent;
            head_ent = head_ent->next)
        {
            ptr_table_store(our_table, head_ent->oldval, head_ent->newval);
        }
    }
}

SV *_PtrTable_get(SV *self, UV addr)
{
    PTR_TBL_t *our_table = get_our_table(self);
    SV *ret = ptr_table_fetch(our_table, (void*)addr);
    if(!ret) {
        ret = &PL_sv_undef;
    } else {
        ret = newRV_inc(ret);
    }
    /*else*/
    return ret;
}

void _PtrTable_freecopied(SV *self)
{
    PTR_TBL_t *our_table = get_our_table(self);
    ptr_table_free(our_table);
}