using Mocking
Mocking.enable()

using AWSTools
using Base.Test

import AWSTools.Docker
import AWSTools.CloudFormation: stack_description
import AWSTools.ECR: get_login
import AWSTools.S3: S3Results

include("mock.jl")

@testset "AWSTools Tests" begin
    @testset "Basic Tests" begin
        @testset "CloudFormation" begin
            patch = @patch describe_stacks(args...) = DESCRIBE_STACKS_RESP

            apply(patch; debug=true) do
                resp = stack_description("stackname")

                @test resp == Dict(
                    "StackId"=>"Stack Id",
                    "StackName"=>"Stack Name",
                    "Description"=>"Stack Description"
                )
            end
        end

        @testset "ECR" begin
            @testset "Basic login" begin
                patch = @patch get_authorization_token() = GET_AUTH_TOKEN_RESP

                apply(patch; debug=true) do
                    docker_login = get_login()
                    @test docker_login == `docker login -u token -p password endpoint`
                end
            end

            @testset "Login specifying registry Id" begin
                patch = @patch get_authorization_token(; registryIds=Vector{Int}(1)) = GET_AUTH_TOKEN_RESP

                apply(patch; debug=true) do
                    docker_login = get_login([1])
                    @test docker_login == `docker login -u token -p password endpoint`
                end
            end
        end

        @testset "S3" begin
            function test_S3(folder::String)
                DATA_DIR = joinpath(@__DIR__, "..", folder)
                object = S3Results("AWSTools", "test")
                download(object, DATA_DIR)
                @test readdir(DATA_DIR) == ["test"]
            end

            patch = @patch get_object(; Bucket="", Key="") = GET_OBJECT_RESP

            apply(patch; debug=true) do
                mktempdir(test_S3, joinpath(@__DIR__))
            end
        end
    end

    @testset "Online Tests" begin
        @testset "ECR" begin
            docker_login = get_login()

            resp = split(replace(string(docker_login), '`', ""), ' ')
            @test resp[1] == "docker"
            @test resp[2] == "login"
            @test resp[3] == "-u"
            @test resp[5] == "-p"
            @test length(resp) == 7
        end
    end
end
