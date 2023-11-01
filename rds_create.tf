
####################################################
########### DB LOCALS
####################################################

locals {
  db_cluster_resource_id = aws_rds_cluster.testdb_database_cluster_psql[0].cluster_resource_id

  db_cluster_identifier = aws_rds_cluster.testdb_database_cluster_psql[0].cluster_identifier

  db_endpoint = aws_rds_cluster.testdb_database_cluster_psql[0].endpoint

  db_arn =  aws_rds_cluster.testdb_database_cluster_psql[0].arn

  db_master_username = aws_rds_cluster.testdb_database_cluster_psql[0].master_username
  
  microservice_name = "testdb"

  secret_prefix = "${local.environment_id}/{local.microservice_name}"
  
  database_admin_username = "administrator"
  
  database_application_username = "db_app_user"

  database_read_only_username = "db_ro_user"

}

####################################################
########### RESOURCES
####################################################

resource "aws_cloudwatch_log_group" "sl_database_log_group_psql" {
  name              = "/aws/rds/cluster/testdb-${local.environment_id}-psql/error"
  retention_in_days = var.cloudwatch_logs_retention

  tags = merge(
    local.common_tags,
    {
      "Name" = "testdb-${local.environment_id}-psql"
    },
  )
}

resource "aws_cloudwatch_log_group" "provision_database_labmda_log_group_psql" {
  name              = "/aws/lambda/${local.environment_id}-testdb-ProvisionDatabase-Psql"
  retention_in_days = var.cloudwatch_logs_retention

  tags = merge(
    local.common_tags,
    {
      "Name" = "${local.environment_id}-testdb-ProvisionDatabase-Psql"
    },
  )
}

resource "aws_rds_cluster" "testdb_database_cluster_psql" {
  depends_on              = [aws_cloudwatch_log_group.sl_database_log_group_psql]
  apply_immediately       = true
  cluster_identifier      = "testdb-${local.environment_id}-databasev2"
  backup_retention_period = var.aurora_retention_period
  engine                  = "aurora-postgresql"
  engine_version          = var.engine_version
  engine_mode             = "provisioned"
  db_subnet_group_name    = aws_db_subnet_group.asl_database_subnet_group[0].name
  deletion_protection     = var.db_deletion_protection
  master_username         = local.database_admin_username
  master_password         = random_password.master_password.result
  database_name           = local.database_name
  skip_final_snapshot     = true
  vpc_security_group_ids  = [aws_security_group.asl_database_security_group[0].id]
  storage_encrypted       = var.db_encrypted

  serverlessv2_scaling_configuration {
    max_capacity = var.database_max_capacity
    min_capacity = var.database_min_capacity
  }

  tags = merge(
    local.common_tags,
    {
      "Name" = "testdb-${local.environment_id}-databasev2"
    },
  )

}

resource "aws_rds_cluster_instance" "database_cluster_instances" {
  identifier         = "testdb-${local.environment_id}-databasev2-instance"
  apply_immediately  = true
  cluster_identifier = aws_rds_cluster.testdb_database_cluster_psql[0].id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.testdb_database_cluster_psql[0].engine
  engine_version     = aws_rds_cluster.testdb_database_cluster_psql[0].engine_version

  tags = merge(
    local.common_tags,
    {
      "Name" = "testdb-${local.environment_id}-databasev2-instance"
    },
  )
}

resource "aws_secretsmanager_secret" "database_admin_password" {
  count       = length(local.database_admin_users)
  name        = "${local.secret_prefix}/${local.db_cluster_resource_id}/${element(local.database_admin_users, count.index)}"
  description = "RDS database password for administrator database"

  tags = merge(
    local.common_tags,
    {
      "Name" = " database password"
    },
  )
}

resource "aws_secretsmanager_secret_version" "database_admin_password_version" {
  count =  length(local.database_admin_users)
  secret_id = element(
    aws_secretsmanager_secret.database_admin_password.*.arn,
    count.index,
  )
  secret_string = "{\"username\":\"${element(local.database_admin_users, count.index)
  }\",\"password\":\"${element(local.database_admin_passwords, count.index)}\"}"
}

resource "aws_secretsmanager_secret" "database_user_psql" {
  count       = length(local.database_usernames_data_api)
  name        = "${local.secret_prefix}/${local.db_cluster_resource_id}/${element(local.database_usernames_data_api, count.index)}"

  tags = merge(
    local.common_tags,
    {
      "Name" = "${local.secret_prefix}/${local.db_cluster_resource_id}/${element(local.database_usernames_data_api, count.index)}"
    },
  )
}

resource "aws_secretsmanager_secret_version" "database_user_version_psql" {
  count     = length(local.database_usernames_data_api)
  secret_id = element(aws_secretsmanager_secret.database_user_psql.*.arn, count.index)
  secret_string = "{\"username\":\"${element(local.database_usernames_data_api, count.index)
  }\",\"password\":\"${element(local.database_passwords_data_api, count.index)}\"}"
}

####################################################
########### Provision database resources
####################################################

resource "aws_lambda_function" "provision_database_lambda_psql" {
  depends_on = [
    aws_rds_cluster.testdb_database_cluster_psql,
    aws_rds_cluster_instance.database_cluster_instances,
    aws_secretsmanager_secret.database_user_psql,
    aws_cloudwatch_log_group.provision_database_labmda_log_group_psql,
  ]
  function_name = "${local.environment_id}-testdb-ProvisionDatabase-Psql"
  description   = "Creates database and new tables. Triggered by null_resource during installation."
  role          = aws_iam_role.provision_database_lambda_role.arn
  handler       = "provision_database_psql.lambda_handler"
  runtime       = "python3.8"

  vpc_config {
    security_group_ids = [aws_security_group.asl_api_security_group.id]
    subnet_ids         = data.terraform_remote_state.environment_state.outputs.private_subnets
  }

  environment {
    variables = {
      DATABASE_USERNAME             = local.database_admin_username
      DATABASE_APPLICATION_USERNAME = local.database_application_username
      DATABASE_READ_ONLY_USERNAME   = local.database_read_only_username
      DATABASE_ENDPOINT_URL         = local.db_endpoint
      ENVIRONMENT                   = local.environment_id
      DATABASE_CLUSTER_RESOURCE_ID  = local.db_cluster_resource_id
      DATABASE_NAME                 = local.database_name
      DATABASE_ENV_NAME             = local.database_env_name
	  MICORSERVICE_NAME             = local.microservice_name
    }
  }

  timeout          = var.provisiondb_lambda_timeout
  memory_size      = var.provisiondb_lambda_memory
  filename         = "provision_database_psql.zip"
  source_code_hash = filebase64sha256("provision_database_psql.zip")

  tags = merge(
    local.common_tags,
    {
      "Name" = "${local.environment_id}-testdb-ProvisionDatabase-Psql"
    },
  )
}


resource "null_resource" "provision_database_psql" {
  depends_on = [
    aws_rds_cluster.testdb_database_cluster_psql,
    aws_lambda_function.provision_database_lambda_psql,
    aws_iam_role.provision_database_lambda_role,
  ]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOF
aws lambda wait function-active --function-name arn:aws:lambda:${var.target_region}:${data.aws_caller_identity.current.account_id}:function:${aws_lambda_function.provision_database_lambda_psql.function_name} --region ${var.target_region};
aws lambda invoke --region ${var.target_region} --function-name arn:aws:lambda:${var.target_region}:${data.aws_caller_identity.current.account_id}:function:${aws_lambda_function.provision_database_lambda_psql.function_name} --payload file://provision_database.json provision_database.out --cli-binary-format raw-in-base64-out
EOF

  }
}
