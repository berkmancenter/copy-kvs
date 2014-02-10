package Storage::Handler::GridFS;

# class for storing / loading files in GridFS (MongoDB)

use strict;
use warnings;

use Moose;
with 'Storage::Handler';

use MongoDB 0.700.0;
use MongoDB::GridFS;

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init({level => $DEBUG, utf8=>1, layout => "%d{ISO8601} [%P]: %m%n"});

use POSIX qw(floor);

use Storage::Iterator::GridFS;

# MongoDB's number of read / write attempts
# (in case waiting 60 seconds for the read / write to happen doesn't help, the instance should
#  retry writing a couple of times)
use constant MONGODB_READ_ATTEMPTS  => 3;
use constant MONGODB_WRITE_ATTEMPTS => 3;


# Configuration
has '_config_host' => ( is => 'rw' );
has '_config_port' => ( is => 'rw' );
has '_config_database' => ( is => 'rw' );
has '_config_timeout' => ( is => 'rw' );

# MongoDB client, GridFS instance (lazy-initialized to prevent multiple forks using the same object)
has '_mongodb_client' => ( is => 'rw' );
has '_mongodb_database' => ( is => 'rw' );
has '_mongodb_gridfs' => ( is => 'rw' );
has '_mongodb_fs_files_collection' => ( is => 'rw' );

# Process PID (to prevent forks attempting to clone the MongoDB accessor objects)
has '_pid' => ( is => 'rw' );


# Constructor
sub BUILD {
    my $self = shift;
    my $args = shift;

    if (MONGODB_READ_ATTEMPTS < 1) {
        LOGDIE("MONGODB_READ_ATTEMPTS must be >= 1");
    }
    if (MONGODB_WRITE_ATTEMPTS < 1) {
        LOGDIE("MONGODB_WRITE_ATTEMPTS must be >= 1");
    }

    $self->_config_host($args->{host} || 'localhost');
    $self->_config_port($args->{port} || 27017);
    $self->_config_database($args->{database}) or LOGDIE("Database is not defined.");
    $self->_config_timeout($args->{timeout} || -1);
    $self->_pid($$);
}

# Validate ObjectId
# (only ObjectIds generated by MongoDB are supported as they contain an insertion timestamp)
sub valid_objectid($)
{
    my $objectid = shift;

    if (length($objectid) == 24 and $objectid =~ /^[0-9a-f]+$/i) {
        return 1;
    } else {
        return 0;
    }
}

sub _connect_to_mongodb_or_die($)
{
    my ( $self ) = @_;

    if ( $self->_pid == $$ and ( $self->_mongodb_client and $self->_mongodb_database and $self->_mongodb_gridfs and $self->_mongodb_fs_files_collection ) )
    {

        # Already connected on the very same process
        return;
    }

    # Timeout should "fit in" at least MONGODB_READ_ATTEMPTS number of retries
    # within the time period (unless it's "no timeout")
    my $query_timeout = ($self->_config_timeout == -1 ? -1 : floor(($self->_config_timeout / MONGODB_READ_ATTEMPTS) - 1));
    if ($query_timeout != -1 and $query_timeout < 10) {
        LOGDIE("MongoDB query timeout ($query_timeout s) is too small.");
    }

    eval {

        # Connect
        $self->_mongodb_client(MongoDB::MongoClient->new(
            host => $self->_config_host,
            port => $self->_config_port,
            query_timeout => ($query_timeout == -1 ? -1 : $query_timeout * 1000)
        ));
        unless ( $self->_mongodb_client )
        {
            LOGDIE("Unable to connect to MongoDB (" . $self->_config_host . ":" . $self->_config_port . ").");
        }

        $self->_mongodb_database($self->_mongodb_client->get_database( $self->_config_database ));
        unless ( $self->_mongodb_database )
        {
            LOGDIE("Unable to choose a MongoDB database '" . $self->_config_database . "'.");
        }

        $self->_mongodb_fs_files_collection($self->_mongodb_database->get_collection('fs.files'));
        unless ($self->_mongodb_fs_files_collection) {
            LOGDIE("Unable to use MongoDB database's '" . $self->_config_database . "' collection 'fs.files'.");
        }

        $self->_mongodb_gridfs($self->_mongodb_database->get_gridfs);
        unless ( $self->_mongodb_gridfs )
        {
            LOGDIE("Unable to use MongoDB database '" . $self->_config_database . "' as GridFS database.");
        }
    };
    if ($@) {
        LOGDIE("Unable to initialize GridFS storage handler because: $@");
    }

    # Save PID
    $self->_pid($$);

    INFO("Initialized GridFS storage at "
         . $self->_config_host . ":"
         . $self->_config_port . "/"
         . $self->_config_database . ") with query timeout = "
         . ($query_timeout == -1 ? "no timeout" : "$query_timeout s" )
         . ", read attempts = " . MONGODB_READ_ATTEMPTS
         . ", write attempts = " . MONGODB_WRITE_ATTEMPTS);
}

sub head($$)
{
    my ( $self, $filename ) = @_;

    $self->_connect_to_mongodb_or_die();

    # MongoDB sometimes times out when reading because it's busy creating a new data file,
    # so we'll try to read several times
    my $attempt_to_head_succeeded = 0;
    my $file                      = undef;
    for ( my $retry = 0 ; $retry < MONGODB_READ_ATTEMPTS ; ++$retry )
    {
        if ( $retry > 0 )
        {
            WARN("Retrying ($retry)...");
        }

        eval {

            # HEAD
            $file = $self->_mongodb_gridfs->find_one( { 'filename' => $filename } );

            $attempt_to_head_succeeded = 1;
        };

        if ( $@ )
        {
            WARN("Attempt to check if file '$filename' exists on GridFS didn't succeed because: $@");
        }
        else
        {
            last;
        }
    }

    unless ( $attempt_to_head_succeeded )
    {
        LOGDIE("Unable to HEAD '$filename' on GridFS after " . MONGODB_READ_ATTEMPTS . " retries.");
    }

    if ( $file )
    {
        return 1;
    } else {
        return 0;
    }
}

sub delete($$)
{
    my ( $self, $filename ) = @_;

    $self->_connect_to_mongodb_or_die();

    # MongoDB sometimes times out when deleting because it's busy creating a new data file,
    # so we'll try to delete several times
    my $attempt_to_delete_succeeded = 0;
    for ( my $retry = 0 ; $retry < MONGODB_WRITE_ATTEMPTS ; ++$retry )
    {
        if ( $retry > 0 )
        {
            WARN("Retrying ($retry)...");
        }

        eval {

            # Remove file(s) if already exist(s) -- MongoDB might store several versions of the same file
            while ( my $file = $self->_mongodb_gridfs->find_one( { 'filename' => $filename } ) )
            {
                # "safe -- If true, each remove will be checked for success and die on failure."
                $self->_mongodb_gridfs->remove( { 'filename' => $filename }, { safe => 1 } );
            }

            $attempt_to_delete_succeeded = 1;
        };

        if ( $@ )
        {
            WARN("Attempt to delete file '$filename' from GridFS didn't succeed because: $@");
        }
        else
        {
            last;
        }
    }

    unless ( $attempt_to_delete_succeeded )
    {
        LOGDIE("Unable to delete '$filename' from GridFS after " . MONGODB_WRITE_ATTEMPTS . " retries.");
    }

    return 1;
}

sub put($$$)
{
    my ( $self, $filename, $contents ) = @_;

    $self->_connect_to_mongodb_or_die();

    my $gridfs_id;

    # MongoDB sometimes times out when writing because it's busy creating a new data file,
    # so we'll try to write several times
    for ( my $retry = 0 ; $retry < MONGODB_WRITE_ATTEMPTS ; ++$retry )
    {
        if ( $retry > 0 )
        {
            WARN("Retrying ($retry)...");
        }

        eval {

            # Remove file(s) if already exist(s) -- MongoDB might store several versions of the same file
            while ( my $file = $self->_mongodb_gridfs->find_one( { 'filename' => $filename } ) )
            {
                INFO("Removing existing file '$filename'....");
                $self->delete( $filename );
            }

            # Write
            my $basic_fh;
            open( $basic_fh, '<', \$contents );
            $gridfs_id = $self->_mongodb_gridfs->put( $basic_fh, { 'filename' => $filename } );
            unless ( $gridfs_id )
            {
                LOGDIE("MongoDB's ObjectId is empty.");
            }
        };

        if ( $@ )
        {
            WARN("Attempt to write to '$filename' didn't succeed because: $@");
        }
        else
        {
            last;
        }
    }

    unless ( $gridfs_id )
    {
        LOGDIE("Unable to write '$filename' to GridFS after " . MONGODB_WRITE_ATTEMPTS . " retries.");
    }

    return 1;
}

sub get($$)
{
    my ( $self, $filename ) = @_;

    $self->_connect_to_mongodb_or_die();

    # MongoDB sometimes times out when reading because it's busy creating a new data file,
    # so we'll try to read several times
    my $attempt_to_read_succeeded = 0;
    my $file                      = undef;
    for ( my $retry = 0 ; $retry < MONGODB_READ_ATTEMPTS ; ++$retry )
    {
        if ( $retry > 0 )
        {
            WARN("Retrying ($retry)...");
        }

        eval {

            my $id = MongoDB::OID->new( filename => $filename );

            # Read
            my $gridfs_file = $self->_mongodb_gridfs->find_one( { 'filename' => $filename } );
            unless ( defined $gridfs_file )
            {
                die "GridFS: unable to find file with filename '$filename'.";
            }
            $file                      = $gridfs_file->slurp;
            $attempt_to_read_succeeded = 1;
        };

        if ( $@ )
        {
            WARN("Attempt to read from '$filename' didn't succeed because: $@");
        }
        else
        {
            last;
        }
    }

    unless ( $attempt_to_read_succeeded )
    {
        LOGDIE("Unable to read '$filename' from GridFS after " . MONGODB_READ_ATTEMPTS . " retries.");
    }

    unless ( defined( $file ) )
    {
        LOGDIE("Could not get file from GridFS for filename '$filename'");
    }

    return $file;
}

sub list_iterator($;$)
{
    my ( $self, $filename_offset ) = @_;

    $self->_connect_to_mongodb_or_die();

    my $iterator;
    eval {
        # See README.mdown for the explanation of why we don't use MongoDB::Cursor here
        my $iterator = Storage::Iterator::GridFS->new(fs_files_collection => $self->_mongodb_fs_files_collection,
                                                      offset => $filename_offset,
                                                      read_attempts => MONGODB_READ_ATTEMPTS);
    };
    if ($@ or (! $iterator)) {
        LOGDIE("Unable to create GridFS iterator for filename offset '$filename_offset'");
        return undef;
    }

    return $iterator;
}

no Moose;    # gets rid of scaffolding

1;
