using AWSTools.S3
using FilePaths

using AWSTools.CloudFormation: stack_output
using AWSTools.S3: list_files, sync_key
using AWSSDK.S3: put_object, create_bucket
using Compat: @info, @warn
using Compat.UUIDs

setlevel!(getlogger(AWSTools.S3), "info")

# Enables the running of the "batch" online tests. e.g ONLINE=batch
const ONLINE = strip.(split(get(ENV, "ONLINE", ""), r"\s*,\s*"))

# Get the stackname that has the CI testing bucket name (used by gitlab ci)
const AWS_STACKNAME = get(ENV, "AWS_STACKNAME", "")

# Run the online S3 tests on the bucket specified
const AWS_BUCKET = get(
    ENV,
    "AWS_BUCKET",
    isempty(AWS_STACKNAME) ? "" : replace(stack_output(AWS_STACKNAME)["TestBucketArn"], r"^arn:aws:s3:::", s"")
)


function compare(src_file::AbstractPath, dest_file::AbstractPath)
    @test isfile(dest_file)
    @test basename(dest_file) == basename(src_file)
    @test size(dest_file) == size(src_file)
    @test modified(dest_file) >= modified(src_file)

    # Test file contents are equal
    @test read(dest_file, String) == read(src_file, String)
end

function compare_dir(src_dir::AbstractPath, dest_dir::AbstractPath)
    @test isdir(dest_dir)
    @test readdir(dest_dir) == readdir(src_dir)
end


@testset "S3" begin

    @testset "Download object" begin
        patches = [
            @patch get_object(config, args) = ""
            list_S3_objects_patch[8]
        ]

        mktempdir() do tmp_dir
            apply(patches) do
                # Download to local file
                s3_object = S3Path("bucket", "test_file")
                localfile = Path((tmp_dir, "local_file"))
                downloaded_file = download(s3_object, localfile)
                @test readdir(tmp_dir) == ["local_file"]
                @test isa(downloaded_file, AbstractPath)

                # Download to directory
                s3_object = S3Path("bucket", "test_file")
                downloaded_file = download(s3_object, AbstractPath(tmp_dir))
                @test readdir(tmp_dir) == ["local_file", "test_file"]
                @test isa(downloaded_file, AbstractPath)
            end
        end
    end

    @testset "S3Path creation" begin
        # Test basic
        bucket = "bucket"
        key = "key"

        path1 = S3Path("s3://$bucket/$key")
        path2 = S3Path("$bucket", "$key")
        path3 = S3Path(("s3://$bucket", "$key"))

        @test path1.bucket == "$bucket"
        @test path1.key == "$key"
        @test parts(path1) == ("s3://$bucket", "$key")

        @test path1 == path2 == path3

        @test isfile(path1) == true

        # Test longer key
        bucket = "bucket"
        key = "folder/key"
        pieces = ("s3://$bucket", "folder", "key")

        path1 = S3Path("s3://$bucket/$key")
        @test path1.bucket == "$bucket"
        @test path1.key == "$key"
        @test parts(path1) == pieces

        path2 = S3Path("$bucket", "$key")
        @test path2.bucket == "$bucket"
        @test path2.key == "$key"
        @test parts(path2) == pieces

        path3 = S3Path(pieces)
        @test path3.bucket == "$bucket"
        @test path3.key == "$key"
        @test parts(path3) == pieces

        @test path1 == path2 == path3

        @test isfile(path1) == true

         # Test folder
        bucket = "bucket"
        key = "folder1/folder2/"
        pieces = ("s3://$bucket", "folder1", "folder2", "")

        path1 = S3Path("s3://$bucket/$key")
        @test path1.bucket == "$bucket"
        @test path1.key == "$key"
        @test parts(path1) == pieces

        path2 = S3Path("$bucket", "$key")
        @test path2.bucket == "$bucket"
        @test path2.key == "$key"
        @test parts(path2) == pieces

        path3 = S3Path(pieces)
        @test path3.bucket == "$bucket"
        @test path3.key == "$key"
        @test parts(path3) == pieces

        @test path1 == path2 == path3

        @test isdir(path1) == true
        joined_path = join(path1, "myfile")
        @test joined_path == S3Path("s3://$bucket/$(key)myfile")
        @test parts(joined_path) == ("s3://$bucket", "folder1", "folder2", "myfile")

        # Test bucket
        bucket = "bucket"
        key = ""
        pieces = ("s3://$bucket", "")

        path1 = S3Path("s3://$bucket/$key")
        @test path1.bucket == "$bucket"
        @test path1.key == "$key"
        @test parts(path1) == pieces

        path2 = S3Path("$bucket", "$key")
        @test path2.bucket == "$bucket"
        @test path2.key == "$key"
        @test parts(path2) == pieces

        path3 = S3Path(pieces)
        @test path3.bucket == "$bucket"
        @test path3.key == "$key"
        @test parts(path3) == pieces

        @test path1 == path2 == path3

        @test isdir(path1) == true
        joined_path = join(path1, "myfile")
        @test joined_path == S3Path("s3://$bucket/$(key)myfile")
        @test parts(joined_path) == ("s3://$bucket", "myfile")

        joined_path = join(path1, "folder/")
        @test joined_path == S3Path("s3://$bucket/$(key)folder/")
        @test parts(joined_path) == ("s3://$bucket", "folder", "")

        joined_path = join(path1, "")
        @test joined_path == path1
        @test parts(joined_path) == pieces
    end

    @testset "Syncing" begin

        @testset "Sync two local directories" begin
            # Create files to sync
            src = Path(mktempdir())
            src_file = join(src, "file1")
            write(src_file, "Hello World!")

            src_folder = join(src, "folder1")
            mkdir(src_folder)
            src_folder_file = join(src_folder, "file2")
            write(src_folder_file, "") # empty file

            src_folder2 = join(src_folder, "folder2") # nested folders
            mkdir(src_folder2)
            src_folder2_file = join(src_folder2, "file3")
            write(src_folder2_file, "Test")

            # Sync files
            dest = Path(mktempdir())
            sync(src, dest)

            # Test directories are the same
            @test readdir(dest) == readdir(src)

            # Get paths of new files
            dest_file = join(dest, "file1")
            dest_file_mtime = modified(dest_file)
            dest_folder = join(dest, basename(src_folder))
            dest_folder_file = join(dest_folder, "file2")
            dest_folder2 = join(dest_folder, basename(src_folder2))
            dest_folder2_file = join(dest_folder2, "file3")

            # Test that contents get copied over and size is equal
            compare(src_file, dest_file)
            compare(src_folder_file, dest_folder_file)
            compare(src_folder2_file, dest_folder2_file)

            compare_dir(src_folder, dest_folder)
            compare_dir(src_folder2, dest_folder2)

            @testset "Sync modified dest file" begin
                # Modify a file in dest
                write(dest_folder_file, "Modified in dest.")

                # Syncing overwrites the newer file in dest because it is of different size
                sync(src, dest)
                compare(src_folder_file, dest_folder_file)
            end

            @testset "Sync modified src file" begin
                 # Modify a file in src
                write(src_folder_file, "Modified in src.")

                # Test that syncing overwrites the modified file in dest
                sync(src, dest)
                compare(src_folder_file, dest_folder_file)

                # Test other files weren't updated
                @test modified(dest_file) == dest_file_mtime
            end

            @testset "Sync newer dest file" begin
                # This is the case because a newer file of the same size is usually the
                # result of an uploaded file always having a newer last_modified time.

                # Modify a file in dest
                write(dest_folder_file, "Modified in dest")

                # Test that syncing doesn't overwrite the newer file in dest
                sync(src, dest)
                @test read(dest_folder_file, String) != read(src_folder_file, String)
            end

            @testset "Sync incompatible types" begin
                @test_throws ArgumentError sync(src, dest_folder_file)
                @test_throws ArgumentError sync(src_folder_file, dest)
            end

            remove(src_file)

            @testset "Sync deleted file with no delete flag" begin
                # Syncing should not delete the file in the destination
                sync(src, dest)
                @test isfile(dest_file)
            end

            @testset "Sync deleted files with delete flag" begin
                # Test that syncing deletes the file in dest
                sync(src, dest; delete=true)
                @test !isfile(dest_file)

                remove(Path(src_folder2); recursive=true)

                @test isfile(dest_folder2_file)
                @test isdir(dest_folder2)

                sync(src, dest; delete=true)

                @test !isfile(dest_folder2_file)
                @test !isdir(dest_folder2)
                @test isdir(dest_folder)
            end

            @testset "Sync files" begin
                @test !isfile(dest_file)

                write(src_file, "Test")

                sync(src_file, dest_file)

                @test isfile(dest_file)
                compare(src_file, dest_file)
            end

            @testset "Sync empty directory" begin
                remove(src; recursive=true)

                sync(src, dest, delete=true)

                @test isempty(readdir(src))
                @test !isfile(dest) && !isdir(dest)
            end

            @testset "Sync non existent directories" begin
                remove(src; recursive=true)
                isdir(dest) && remove(dest; recursive=true)

                # Test syncing creates non existent local directories
                sync(src, dest)

                @test isdir(src)
                @test isdir(dest)

                remove(src)
                remove(dest)
            end
        end

        @testset "Sync two s3 directories" begin
            # Verify we don't run into errors and that the expected parameters are
            # passed to aws calls (via the patches)
            @testset "Sync two buckets" begin
                patches = [
                    copy_object_patch[1],
                    list_S3_objects_patch[1],
                    delete_object_patch[1],
                ]

                apply(patches) do
                    sync("s3://bucket-1/", "s3://bucket-2/")
                    sync("s3://bucket-1/", "s3://bucket-2/", delete=true)

                end
            end

            @testset "Sync prefix in bucket to another bucket" begin
                patches = [
                    copy_object_patch[2],
                    list_S3_objects_patch[2],
                    delete_object_patch[2],
                ]

                apply(patches) do
                    sync("s3://bucket-1/dir1/", "s3://bucket-2/")
                    sync("s3://bucket-1/dir1/", "s3://bucket-2/", delete=true)
                end
            end

            @testset "Sync two prefixes in same bucket" begin
                patches = [
                    copy_object_patch[3],
                    list_S3_objects_patch[3],
                    delete_object_patch[3],
                ]

                apply(patches) do
                    sync("s3://bucket-1/dir1/", "s3://bucket-1/dir2/")
                    sync("s3://bucket-1/dir1/", "s3://bucket-1/dir2/", delete=true)
                end
            end

            @testset "Sync prefixes in different buckets" begin
                patches = [
                    copy_object_patch[4],
                    list_S3_objects_patch[4],
                    delete_object_patch[4],
                ]

                apply(patches) do
                    sync("s3://bucket-1/dir1/", "s3://bucket-2/dir2/")
                    sync("s3://bucket-1/dir1/", "s3://bucket-2/dir2/", delete=true)
                end
            end

            @testset "Sync bucket to prefix" begin
                patches = [
                    copy_object_patch[5],
                    list_S3_objects_patch[5],
                    delete_object_patch[5],
                ]

                apply(patches) do
                    sync("s3://bucket-1/", "s3://bucket-2/dir2/")
                    sync("s3://bucket-1/", "s3://bucket-2/dir2/", delete=true)
                end
            end

        end

        @testset "Sync local folder to s3 bucket" begin
            patches = [
                put_object_patch[6],
                list_S3_objects_patch[6],
                delete_object_patch[6],
            ]

            apply(patches) do

                src = mktempdir()

                src_file = "$src/file"
                # touch(src_file)
                write(src_file, "Hello World!")

                src_folder = "$src/folder"
                mkdir(src_folder)
                src_folder_file = "$src_folder/file"
                touch(src_folder_file) # empty file

                sync(src, "s3://bucket-1/")

                # S3 directory was not empty initially, so this will delete all
                # its original files that are not also in src
                sync(src, "s3://bucket-1/", delete=true)

                remove(Path(src); recursive=true)
            end
        end

        @testset "Sync s3 bucket to local folder" begin
            patches = [
                get_object_patch[7],
                list_S3_objects_patch[7],
            ]

            mktempdir() do folder
                apply(patches) do

                    src = AbstractPath("s3://bucket-1/")
                    dest = AbstractPath(folder)

                    sync(src, dest)

                    s3_objects = list_files(src)

                     # Test directories are the same
                    for s3_object in s3_objects
                        dest_file = join(dest, sync_key(src, s3_object))
                        compare(s3_object, dest_file)
                    end

                     @testset "Sync modified dest file" begin
                        # Modify a file in dest
                        s3_object = s3_objects[1]
                        file = join(dest, sync_key(src, s3_object))
                        write(file, "Modified in dest.")

                        # Syncing overwrites the newer file in dest because it is of
                        # different size
                        sync(src, dest)
                        compare(s3_object, file)
                    end

                    @testset "Sync newer dest file" begin
                        # This is the case because a newer file of the same size is usually
                        # the result of an uploaded file always having a newer last_modified
                        # time.

                       # Modify a file in dest
                        s3_object = s3_objects[1]
                        file = join(dest, sync_key(src, s3_object))
                        write(file, "Hello World.")

                        # Test that syncing doesn't overwrite the newer file in dest
                        sync(src, dest)

                        # Test file contents are not equal
                        @test read(file, String) != read(s3_object)
                    end

                    @testset "Sync an object instead of a prefix" begin
                        s3_object_path = join(src, sync_key(src, s3_objects[1]))
                        @test_throws ArgumentError sync(s3_object_path, folder)
                    end
                end
            end
        end

        if "S3" in ONLINE
            @testset "Online" begin
                @info "Running ONLINE S3 tests"

                # Create bucket for tests
                if isempty(AWS_BUCKET)
                    bucket = string("awstools-s3-test-temp-", uuid4())
                    @info "Creating S3 bucket $bucket"
                    create_bucket(Dict("Bucket" => bucket))
                else
                    bucket = AWS_BUCKET
                end

                test_run_id = string(uuid4())

                try
                    @testset "Upload to s3" begin
                        dest = AbstractPath(
                            "s3://$bucket/awstools/$test_run_id/folder3/testfile"
                        )

                        try
                            mktemp() do src, stream
                                write(stream, "Local file src")
                                close(stream)

                                @test list_files(dest) == []

                                uploaded_file = upload(AbstractPath(src), dest)
                                @test isa(uploaded_file, S3Path)

                                @test list_files(dest) == [dest]
                                @test read(dest, String) == "Local file src"
                            end
                        finally
                            remove(dest; recursive=true)
                        end
                    end

                    @testset "Download from s3" begin
                        src = AbstractPath(
                            "s3://$bucket/awstools/$test_run_id/folder4/testfile"
                        )

                        try
                            put_object(Dict(
                                "Body" => "Remote content",
                                "Bucket" => src.bucket,
                                "Key" => src.key,
                             ))

                            @testset "Download to a directory" begin
                                mktempdir() do dest_dir
                                    dest = AbstractPath(dest_dir)

                                    dest_file = download(src, dest)
                                    @test isa(dest_file, AbstractPath)

                                    @test list_files(dest) == [AbstractPath(dest_file)]
                                    @test read(dest_file, String) == "Remote content"
                                end
                            end

                            @testset "Download to a local file" begin
                                mktemp() do dest_file, stream
                                    dest = AbstractPath(dest_file)
                                    close(stream)

                                    dest_file = download(src, dest; overwrite=true)
                                    @test isa(dest_file, AbstractPath)

                                    @test dest_file == String(dest)
                                    @test read(dest, String) == "Remote content"
                                end
                            end

                        finally
                            remove(src; recursive=true)
                        end
                    end

                    @testset "Two S3 directories" begin
                        folder1 = "awstools/$test_run_id/folder1"
                        folder2 = "awstools/$test_run_id/folder2"
                        dir1 = "s3://$bucket/$folder1/"
                        dir2 = "s3://$bucket/$folder2/"

                        src_dir = AbstractPath(dir1)
                        dest_dir = AbstractPath(dir2)

                        # Delete any pre-existing objects in the s3 bucket directories
                        remove(src_dir; recursive=true)
                        remove(dest_dir; recursive=true)

                        s3_objects = [
                            Dict("Bucket" => bucket, "Key" => "$folder1/file1", "Content" => "Hello World!"),
                            Dict("Bucket" => bucket, "Key" => "$folder1/file2", "Content" => ""),
                            Dict("Bucket" => bucket, "Key" => "$folder1/folder/file3", "Content" => "Test"),
                        ]

                        # Set up the source s3 directory
                        for object in s3_objects
                            put_object(Dict(
                                "Body" => object["Content"],
                                "Bucket" => object["Bucket"],
                                "Key" => object["Key"],
                            ))
                        end

                        # Sync files
                        sync(dir1, dir2)

                        # Test directories are the same
                        dir1_files = list_files(src_dir)
                        dir2_files = list_files(dest_dir)

                        src_file = dir1_files[1]
                        dest_file = dir2_files[1]

                        @test !isempty(dir2_files)

                        @test length(dir2_files) == length(s3_objects)
                        @test length(dir2_files) == length(dir1_files)

                        for i in 1:length(dir1_files)
                            file1 = dir1_files[i]
                            key1 = sync_key(src_dir, file1)
                            file2 = dir2_files[i]
                            key2 = sync_key(dest_dir, file2)

                            @test key1 == key2
                            compare(file1, file2)
                        end

                        @testset "Sync modified dest file" begin
                            # Modify a file in dest
                            put_object(Dict(
                                "Body" =>  "Modified in dest.",
                                "Bucket" => dir2_files[1].bucket,
                                "Key" => dir2_files[1].key,
                            ))

                            # Syncing overwrites the newer file in dest because it is of
                            # a different size
                            sync(dir1, dir2)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)

                            file1 = dir1_files[1]
                            key1 = sync_key(src_dir, file1)
                            file2 = dir2_files[1]
                            key2 = sync_key(dest_dir, file2)

                            @test key1 == key2
                            compare(file1, file2)

                            @test read(dir2_files[1], String) == s3_objects[1]["Content"]
                        end

                        @testset "Sync modified src file" begin
                            # Modify a file in src
                            s3_objects[1]["Content"] = "Modified in src."
                            put_object(Dict(
                                "Body" => s3_objects[1]["Content"],
                                "Bucket" => s3_objects[1]["Bucket"],
                                "Key" => s3_objects[1]["Key"],
                            ))

                            # Test that syncing overwrites the modified file in dest
                            sync(dir1, dir2)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)

                            file1 = dir1_files[1]
                            key1 = sync_key(src_dir, file1)
                            file2 = dir2_files[1]
                            key2 = sync_key(dest_dir, file2)

                            @test key1 == key2
                            compare(file1, file2)

                            @test read(dir2_files[1], String) == s3_objects[1]["Content"]
                        end

                        @testset "Sync newer file in dest" begin
                            # This is the case because a newer file of the same size is
                            # usually the result of an uploaded file always having a newer
                            #last_modified time.

                            # Modify a file in dest
                            put_object(Dict(
                                "Body" =>  "Modified in dest",
                                "Bucket" => dir2_files[1].bucket,
                                "Key" => dir2_files[1].key,
                            ))

                            # Test that syncing doesn't overwrite the newer file in dest
                            sync(dir1, dir2)

                            dir2_files = list_files(dest_dir)
                            @test read(dir2_files[1], String) != s3_objects[1]["Content"]
                        end

                        @testset "Sync s3 bucket with object prefix" begin
                            file = "s3://$bucket/$(s3_objects[1]["Key"])"

                            @test_throws ArgumentError sync(file, dir2)
                        end

                        remove(dir1_files[1])

                        @testset "Sync deleted file with no delete flag" begin
                            sync(dir1, dir2)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)

                            @test length(dir2_files) == length(dir1_files) + 1
                        end

                        @testset "Sync deleted files with delete flag" begin
                            # Test that syncing deletes the file in dest
                            sync(dir1, dir2, delete=true)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)
                            @test length(dir2_files) == length(dir1_files)
                        end

                        @testset "Sync files" begin
                            write(src_file, "Test")

                            sync(src_file, dest_file)

                            compare(list_files(src_dir)[1], list_files(dest_dir)[1])
                        end

                        @testset "Sync empty directory" begin
                            remove(src_dir; recursive=true)

                            sync(dir1, dir2, delete=true)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)

                            @test isempty(dir2_files)

                            sync(dir1, dir2)

                            dir1_files = list_files(src_dir)
                            dir2_files = list_files(dest_dir)

                            @test isempty(dir1_files)
                            @test isempty(dir2_files)
                        end

                        # Clean up any files left in the test directories
                        remove(src_dir; recursive=true)
                        remove(dest_dir; recursive=true)
                    end

                finally

                    # Delete bucket if it was explicitly created
                    if isempty(AWS_BUCKET)
                        @info "Deleting S3 bucket $bucket"
                        remove(S3Path("s3://$bucket"); recursive=true)
                    end
                end
            end
        else
            @warn (
                "Skipping AWSTools.S3 ONLINE tests. Set `ENV[\"ONLINE\"] = \"S3\"` to run." *
                "\nCan also optionally specify a test bucket name `ENV[\"AWS_BUCKET\"] = " *
                "\"bucket-name\"`. \nIf `AWS_BUCKET` is not specified, a temporary bucket " *
                "will be created, used, and then deleted."
            )
        end
    end
end


