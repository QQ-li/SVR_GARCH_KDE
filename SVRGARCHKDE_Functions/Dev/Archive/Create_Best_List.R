rm(list = ls())
graphics.off()

setwd(paste0(Sys.getenv("USERPROFILE"), "/Desktop/Master/Master_Thesis/Simulation"))

library(xtable)

source("SVRGARCHKDE_Functions/Dev/Result2Table_Functions.R")
test        <- readRDS("Final_Analysis/Final_Model.rds")
loop_var <- c("EuroStoxx50", "S&P500", "Nikkei225")

model_paras <- result <- vector("list", length(loop_var)) 
names(model_paras) <- loop_var  
project_folder     <- "From1996to2006_ZeroMean"


for(i in 1:3){
  
  
  series_name        <- loop_var[i]  


###############################################################################
# Get data
###############################################################################

path2data     <- paste0("Tuning\\Results\\RDS_", series_name, "\\", project_folder, "\\VaR\\")
start_load    <- Sys.time()
files         <- lapply(file.path(path2data, list.files(path2data)), readRDS)
end_load      <- Sys.time()
end_load - start_load




###############################################################################
# Get Christoffersons LR test statistic for every list element
###############################################################################

# Get results of tests
probs              <- c(0.005, 0.01, 0.025, 0.05)  # x%-Quantiles used in results table
n                  <- length(files)
list_table         <- lapply(1:n, function(x) arrange_results_df(files[[x]][[1]], probs, "SVM_KDE", "S&P500"))

grid_df            <- Reduce("rbind", lapply(1:n, function(x) cbind(rownames(files[[x]][[2]]),
                                                                    rbind(files[[x]][[2]],
                                                                          files[[x]][[2]],
                                                                          files[[x]][[2]],
                                                                          files[[x]][[2]]))))
names(grid_df)[1]  <- "model"


# Convert list to data frame
df                 <- cbind(grid_df, Reduce("rbind", list_table))
df_sorted          <- df[order(-df$Quantile, df$Series, df$UC, df$Model, decreasing = TRUE),]


get_best_paramters <- function(prob){
  
  df <- df_sorted[df_sorted$Quantile == prob,]
  #df$UC_Rank <- rank(df$UC, ties.method = "max")
  #df$DUR_Rank <- rank(df$DUR, ties.method = "max")
  #df$Rank     <- df$UC_Rank + df$DUR_Rank
  # df$UC_DUR    <- df$UC + df$DUR
  
  return(df)
  
}


df_05 <- get_best_paramters(0.5)
df_1 <- get_best_paramters(1)
df_25 <- get_best_paramters(2.5)
df_5 <- get_best_paramters(5)

head_n <- 1

df_paras <- rbind(head(df_05[order(df_05$CC, decreasing = TRUE),], head_n),
                  head(df_1[order(df_1$CC, decreasing = TRUE),], head_n),
                  head(df_25[order(df_25$CC, decreasing = TRUE),], head_n),
                  head(df_5[order(df_5$CC, decreasing = TRUE),], head_n))

df_paras_sub <- df_paras[, c("Quantile", "cost", "gamma", "psi")]
names(df_paras_sub) <- c("alpha", "c", "sigma", "psi")

model_paras[[series_name]] <- list(VaR = df_paras_sub)

}

rm(list = ls()[which(ls() != "model_paras")])
