#
# Functions for processing JHU simulation files 
# Ryan McCorvie
# Copyright 2020
#

shhh <- suppressPackageStartupMessages # It's a library, so shhh!

shhh( require( "arrow" ))
shhh(require( "lubridate" ))
shhh(require( "tidyverse" ))
shhh(require( "argparse"))
shhh(require( "aws.s3" ))

AWS_ACCESS_KEY_ID     = ""
AWS_SECRET_ACCESS_KEY = ""
AWS_DEFAULT_REGION    = "us-east-2"
S3_BUCKET_NAME        = "jhumodelaggregates"

CA_FIPS_REGEX = "^06[0-9]{3}$"

OUTPUT_SUFFIXES = c( '_mean', '_median', '_q25', '_q75' )
DATA_OUTPUT_COLS = c( 'hosp_occup', 'hosp_admit', 'icu_occup','icu_admit','new_infect','new_deaths' )

JHU_REMAP_COLS = c('hosp_curr','incidH','icu_curr','incidICU','incidI','incidD')
names( JHU_REMAP_COLS) = DATA_OUTPUT_COLS

RUNDATE    = format(today(), "%Y%m%d")
IFR_PREFIX = 'high_death'

SCENARIOS = tribble(
  ~inpath, ~scenario,
  'nonpi-hospitalization/model_output/unifiedNPI/',                                 'No Intervention',
  'kclong-hospitalization/model_output/mid-west-coast-AZ-NV_SocialDistancingLong/', 'Statewide KC 1918',
  'wuhan-hospitalization/model_output/unifiedWuhan/',                               'Statewide Lockdown 8 weeks',
  'hospitalization/model_output/mid-west-coast-AZ-NV_UKFixed_Mild',                 'UK-Fixed-8w-FolMild',
  'hospitalization/model_output/mid-west-coast-AZ-NV_UKFatigue_Mild',               'UK-Fatigue-8w-FolMild',
  'hospitalization/model_output/mid-west-coast-AZ-NV_UKFixed_Pulse',                'UK-Fixed-8w-FolPulse',
  'hospitalization/model_output/mid-west-coast-AZ-NV_UKFatigue_Pulse',              'UK-Fatigue-8w-FolPulse',
  'hospitalization/model_output/mid-west-coast-AZ-NV_Lockdown_continued',           'Continued Lockdown',
  'hospitalization/model_output/mid-west-coast-AZ-NV_Lockdown_fastOpen',            'Fast-paced Reopening',
  'hospitalization/model_output/mid-west-coast-AZ-NV_Lockdown_moderateOpen',        'Moderate-paced Reopening',
  'hospitalization/model_output/mid-west-coast-AZ-NV_Lockdown_slowOpen',            'Slow-paced Reopening',
  'west-coast-AZ-NV_Lockdown_continued',                                            'Continued Lockdown' ,
  'west-coast-AZ-NV_Lockdown_fastOpen',                                             'Fast-paced Reopening',
  'west-coast-AZ-NV_Lockdown_moderateOpen',                                         'Moderate-paced Reopening',
  'west-coast-AZ-NV_Lockdown_slowOpen',                                             'Slow-paced Reopening',
  'hospitalization/model_output/California_Lockdown_continued',                     'Continued Lockdown',
  'hospitalization/model_output/California_Lockdown_fastOpen',                      'Fast-paced Reopening',
  'hospitalization/model_output/California_Lockdown_moderateOpen',                  'Moderate-paced Reopening',
  'hospitalization/model_output/California_Lockdown_slowOpen',                      'Slow-paced Reopening',
  'hospitalization/model_output/California_June_inference',                         'Inference',
)



#' Set the credentials to be able to access appropriate S3 bucket
#'
#' Only sets credentials if they are not already set, unless the override flag is 
#' set to true.  Returns TRUE if operation successful 
#' 

s3_set_credentials <- function( override = FALSE )
{
  keyid <- Sys.getenv("AWS_ACCESS_KEY_ID")
  if( keyid != "" && !override )
    return( TRUE )
  
  all( Sys.setenv(
    "AWS_ACCESS_KEY_ID"     = AWS_ACCESS_KEY_ID,
    "AWS_SECRET_ACCESS_KEY" = AWS_SECRET_ACCESS_KEY,
    "AWS_DEFAULT_REGION"    = AWS_DEFAULT_REGION 
  ))
}

#' Set the credentials to be able to access appropriate S3 bucket
#'
#' Only sets credentials if they are not already set, unless the override flag is 
#' set to true.  Returns TRUE if operation successful 
#' 

upload_to_s3 <- function( outputloc, rundate = RUNDATE, latest=FALSE )
{
  s3_set_credentials()
  
  files <- list.files( file.path( outputloc, rundate ) )
  files <- files[ str_detect( files, "\\.csv$" ) ]
  
  if( !latest )
    print( paste("INFO: uploading", length(files), "files to s3", S3_BUCKET_NAME, "for rundate", rundate ) )
  else
    print( paste("INFO: uploading", length(files), "files to s3", S3_BUCKET_NAME, "latest" ) )
  for( file in files )
  {
    fullpath <- file.path( outputloc, rundate, file )
    if( latest )
      objname = paste( "latest", file, sep= "/")
    else
      objname = paste( rundate, file, sep= "/")
    
    put_object( file= fullpath, object= objname, bucket=S3_BUCKET_NAME)
  }
}


#' Read and filter one parquet file from JHU simulation
#'
#' Read parquet file of simulation and filters by california FIPS, returns a tibble
#'

read_jhu_file <- function( file_name )
{
  input_df = read_parquet(file_name)
  
  # some scenarios (e.g. Statewide KC 1918) have counties outside of CA, so ensure only CA counties present...
  input_df <- input_df %>% filter( str_detect( geoid, CA_FIPS_REGEX ) ) 
  
  #input_df <- input_df %>% filter( time> ymd("20200401") & time <= ymd("20200410"))
  
  return( input_df )
}

#' Read all JHU simulation files for all scenarios
#'
#' Returns a tibble containing to all simulation runs and all scenarios 
#' (for a given IFR assumption)
#'

read_jhu_simulation <- function( inputloc, rundate= RUNDATE, scenarios = SCENARIOS, IFR = IFR_PREFIX )
{
  print(paste("INFO: Reading JHU model output from", inputloc,"for date", rundate))
  # read in the raw model output scenario data for the scenarios in the SCENARIOS global...
  
  out = NULL
  for(scen_idx in 1:nrow(scenarios))
  {
    inpath    = scenarios$inpath[scen_idx]
    scenario  = scenarios$scenario[scen_idx]
    
    input_dir = file.path(inputloc, rundate, inpath)
    if( !dir.exists( input_dir ))
    {
      print( paste("INFO: Skipping",scenario ,"because input directory",input_dir ,"does not exist"))
      next
    }
    
    files <- list.files( input_dir )
    files <- files[ str_detect( files, paste0("^", IFR )) ]
    files <- files[ str_count( files, "[1-9][0-9]*") ==  1 ]
    
    print( paste("INFO: Scenario", scenario, "IFR_PREFIX", IFR, "found", length(files), "simulation files"))
    
    df_list <- vector( mode="list", length = length(files))
    for( idx in 1:length(files ))
    {
      file = files[idx]

      file_num <- as.numeric(str_extract( file, "[1-9][0-9]*"))
      df  <- read_jhu_file( file.path( input_dir, file ))
      df <- df %>% mutate( file_num = file_num, scenario = scenario )
      df_list[[idx]] <- df
      if(idx%%25 ==0 )
        print( paste( "INFO: Processing file", idx, "/", length(files), "( id =",file_num ,")"))
    }
    scen_df <- bind_rows( df_list )
    out <- bind_rows( out, scen_df )
  }
  if( is.null(out))
    stop("ERROR: no simluation files found at ", file.path(inputloc,rundate))
  
  out <- out %>% rename( !!JHU_REMAP_COLS )
  out
}


#' 25th percentile

q25 <- function(x)
  return( quantile(x, 0.25))

#' 50th percentile
q50 <- function(x)
  return( quantile(x, 0.50))

#' 75th percentile
q75 <- function(x)
  return( quantile(x, 0.75))


#' Generate state-level summary statistics from simulation paths
#'
#' Returns a tibble by scenario / date which summarizes statistics across
#' simulation paths

generate_state_summary <- function( jhu_df )
{
  print( paste("INFO: Summarizing state level statistics for simulation" ) )
  
  # net across geoid
  state_summary <- jhu_df %>% group_by( scenario,file_num,time ) %>% 
    select( scenario, file_num, time, all_of(DATA_OUTPUT_COLS))%>%
    summarize_all( list(sum))
  
  # aggregate over file_num
  state_summary <- state_summary %>% 
    group_by( scenario, time ) %>% 
    select( scenario,time,all_of(DATA_OUTPUT_COLS))%>%
    summarize_all( list( mean = mean, median=median, q25 = q25, q75 = q75)) %>%
    ungroup
  
  # this is the column order from the legacy python script
  col_order<-kronecker(DATA_OUTPUT_COLS, OUTPUT_SUFFIXES, FUN = paste0)
  state_summary <- state_summary %>% 
    select( scenario, time, all_of(col_order)) %>%
    arrange( scenario, time ) 
  
  return( state_summary )  
}

#' Generate county-level summary statistics from simulation paths
#'
#' Returns a tibble by scenario / county FIPS / date which summarizes statistics across
#' simulation paths

generate_county_summary <- function( jhu_df )
{
  print( paste("INFO: Summarizing county level statistics for simulation" ) )
  
  # net up to county level
  county_summary <- jhu_df %>% group_by( scenario,file_num,time, geoid ) %>% 
    select( scenario,file_num,time,geoid,all_of(DATA_OUTPUT_COLS))%>%
    summarize_all( list(sum))
  
  # aggregate over file_num
  county_summary <-county_summary %>% 
    group_by( scenario, time, geoid ) %>% 
    select( scenario,time, geoid, all_of(DATA_OUTPUT_COLS))%>%
    summarize_all( list( mean = mean, median=median, q25 = q25, q75 = q75)) %>%
    ungroup
  
  # this is the column order from the legacy python script
  col_order<-kronecker(DATA_OUTPUT_COLS, OUTPUT_SUFFIXES, FUN = paste0)
  county_summary <- county_summary %>% 
    select( scenario, time, geoid, all_of(col_order)) %>%
    arrange( scenario, time, geoid ) 
  
  return( county_summary )  
}


#' Save a summary statistics to appropriate CSVs
#'
#' Saves one csv per scenario
#' 

save_csv_by_scenario <- function( summary_df, suffix = NULL, outputloc = OUTPUTLOC, rundate = RUNDATE )
{
  msg <- "INFO: Writing summary statistics to csv" 
  if( !is.null(suffix) )
    msg <- paste( msg, "( suffix = ",suffix, ")" )
  print( msg )
  
  scenarios <- unique( summary_df$scenario )
  if( length( scenarios ) == 0 )
    stop( "ERROR: no scenarios found - do input files line up with scenarios?" )
  
  for( scenario in scenarios)
  {
    write_me <- summary_df %>% filter( scenario == !!scenario ) %>% select( -scenario )
    
    filename<- str_replace_all( scenario, " ", "_")
    if( !is.null( suffix))
      filename <- paste( filename, suffix, sep=".")
    if( !file.exists( file.path(outputloc,rundate)))
      stop( paste("No directory to write to:",file.path(outputloc,rundate)) )
    filename <- paste( filename, "csv", sep=".")
    write_csv( write_me, file.path( outputloc, rundate, filename )) 
  }
  invisible( summary_df )
}

#' Detect whether this rundate is the most recent rundate
#'

is_latest <- function( outputloc, rundate = RUNDATE )
{
  files <- list.files( outputloc )
  datelike <- files[ str_detect(files, "^[1-9][0-9]{7}$" ) ]

  return( max(datelike) == rundate )
}

#' Load simulation scenarios from raw files, process, and save
#'
#' do_counties controls whether to make summaries by county in addition to state summary
#' 

process_jhu_simulation <- function( inputloc, outputloc, rundate = RUNDATE, do_counties=TRUE )
{
  jhu_simulation <- read_jhu_simulation( inputloc, rundate=rundate )
  
  state_summary <- generate_state_summary( jhu_simulation )
  save_csv_by_scenario( state_summary, NULL, outputloc, rundate )
  
  if( do_counties )
  {
    county_summary <- generate_county_summary( jhu_simulation )
    save_csv_by_scenario( county_summary, "county", outputloc, rundate )
  }
  
  invisible(inputloc)  
}

