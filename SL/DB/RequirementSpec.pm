package SL::DB::RequirementSpec;

use strict;

use Carp;
use Rose::DB::Object::Helpers;

use SL::DB::MetaSetup::RequirementSpec;
use SL::DB::Manager::RequirementSpec;
use SL::Locale::String;

__PACKAGE__->meta->add_relationship(
  items          => {
    type         => 'one to many',
    class        => 'SL::DB::RequirementSpecItem',
    column_map   => { id => 'requirement_spec_id' },
  },
  text_blocks    => {
    type         => 'one to many',
    class        => 'SL::DB::RequirementSpecTextBlock',
    column_map   => { id => 'requirement_spec_id' },
  },
);

__PACKAGE__->meta->initialize;

__PACKAGE__->before_save('_before_save_initialize_not_null_columns');

sub validate {
  my ($self) = @_;

  my @errors;
  push @errors, t8('The title is missing.') if !$self->title;

  return @errors;
}

sub _before_save_initialize_not_null_columns {
  my ($self) = @_;

  $self->previous_section_number(0) if !defined $self->previous_section_number;
  $self->previous_fb_number(0)      if !defined $self->previous_fb_number;

  return 1;
}

sub text_blocks_for_position {
  my ($self, $output_position) = @_;

  return [ sort { $a->position <=> $b->position } grep { $_->output_position == $output_position } @{ $self->text_blocks } ];
}

sub sections {
  my ($self, @rest) = @_;

  croak "This sub is not a writer" if @rest;

  return [ sort { $a->position <=> $b->position } grep { !$_->parent_id } @{ $self->items } ];
}

sub displayable_name {
  my ($self) = @_;

  return sprintf('%s: "%s"', $self->type->description, $self->title);
}

sub create_copy {
  my ($self, %params) = @_;

  return $self->_create_copy(%params) if $self->db->in_transaction;

  my $copy;
  if (!$self->db->do_transaction(sub { $copy = $self->_create_copy(%params) })) {
    $::lxdebug->message(LXDebug->WARN(), "create_copy failed: " . join("\n", (split(/\n/, $self->db->error))[0..2]));
    return undef;
  }

  return $copy;
}

sub _create_copy {
  my ($self, %params) = @_;

  my $copy = Rose::DB::Object::Helpers::clone_and_reset($self);
  $copy->assign_attributes(%params);

  # Clone text blocks.
  $copy->text_blocks(map { Rose::DB::Object::Helpers::clone_and_reset($_) } @{ $self->text_blocks });

  # Save new object -- we need its ID for the items.
  $copy->save;

  my %id_to_clone;

  # Clone items.
  my $clone_item;
  $clone_item = sub {
    my ($item) = @_;
    my $cloned = Rose::DB::Object::Helpers::clone_and_reset($item);
    $cloned->requirement_spec_id($copy->id);
    $cloned->children(map { $clone_item->($_) } @{ $item->children });

    $id_to_clone{ $item->id } = $cloned;

    return $cloned;
  };

  $copy->items(map { $clone_item->($_) } @{ $self->sections });

  # Save the items -- need to do that before setting dependencies.
  $copy->save;

  # Set dependencies.
  foreach my $item (@{ $self->items }) {
    next unless @{ $item->dependencies };
    $id_to_clone{ $item->id }->update_attributes(dependencies => [ map { $id_to_clone{$_->id} } @{ $item->dependencies } ]);
  }

  return $copy;
}

1;
