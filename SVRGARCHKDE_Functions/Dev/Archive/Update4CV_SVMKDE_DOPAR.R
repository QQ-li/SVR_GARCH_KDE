svm_kde_dopar <- function(data, q, block, test, mean_mdl, variance_mdl, delta){
  
  if(nrow(data) < block + test) stop("Number of rows in 'data' is less than block + test")
  
  source("C:/Users/Marius/Desktop/Master/Master_Thesis/Simulation/SVRGARCHKDE_Functions/Source_File/Source_SVRGARCHKDE.R")
  library(doParallel)
  library(quantmod)
  
  allData    <- data
  test_n     <- test 
  block_size <- block
  loop_start <- nrow(allData) - test_n
  loop_end   <- nrow(allData) - 1
  
  # Specify indices for 'foreach'
  loop_idx     <- loop_start:loop_end
  
  i4dopar   <- split(loop_idx, cut(loop_idx, quantile(loop_idx, probs = seq(0, 1, by = 1/length(delta))), include.lowest = TRUE)) 
  starts    <- cumsum(c(min(x), delta + 1))
  loop_idx  <- starts[-length(starts)]
  
  # Reserve data frame to save results
  results    <- data.frame(Mean = numeric(),
                           Upper = numeric(),
                           Lower = numeric(),
                           Vola = numeric())
  
  cl <- makeCluster(2)
  registerDoParallel(cl)

  results <- foreach(i = loop_idx, .combine = "rbind") %dopar% {
    
    source("C:/Users/Marius/Desktop/Master/Master_Thesis/Simulation/SVRGARCHKDE_Functions/Source_File/Source_SVRGARCHKDE.R")
    library(quantmod)
    library(e1071)
    library(zoo)
    
    j            <- which(i == starts)  # Index for delta
    
    x            <- allData[(i-block_size+1):(i + delta[j]),-1]
    y            <- allData[(i-block_size+1):(i + delta[j]),1]
    
    if(mean_mdl == "KDE" | variance_mdl == "KDE"){
      
      KDE_VaR(y, q, kernel = "gaussian")
      
    }else{
      
      svm_kde(x = x, y = y, q = q, mean_mdl = mean_mdl, variance.mdl = variance_mdl, 
              kernel = "gaussian", delta = delta[j])
      
      
    }
    
    
  }
  stopCluster(cl)
  
  results$Vola <- na.locf(results$Vola)
  results      <- plotResults(results, allData, test_n, q)
  
  return(results)
}





svm_kde <- function(x, y, q, mean_mdl, variance.mdl, kernel, delta){
  
  
  #############################################################################
  # 0. Specify data 
  #############################################################################

  # Data for estimation
  x_est <- x[1:(nrow(x) - delta)]
  y_est <- y[1:(nrow(y) - delta)]
    
  # Data for prediction
  #x_pred <- x[(nrow(x) - delta + 1):nrow(x)]
  pred_data <- y[(nrow(y) - delta):nrow(y)]
  

  #############################################################################
  # 1. Fit mean model
  #############################################################################
  
  # Set parameters
  svm_mean_eps     <- mean_mdl$eps
  svm_mean_cost    <- mean_mdl$cost
  sigma            <- mean_mdl$sigma
  svm_mean_gamma   <- 1/(2*sigma^2)
  
  # SVM for mean
  svm_mean         <- svm(x = x_est, y = y_est, 
                          type = "eps-regression", 
                          kernel = "radial",
                          gamma = svm_mean_gamma,
                          cost = svm_mean_cost,
                          epsilon = svm_mean_eps)
  
  # Get fitted values and residual (format as xts for lagging in variance fitting)
  mean             <- xts(x = svm_mean$fitted, order.by = index(y_est))
  eps              <- xts(x = svm_mean$residuals, order.by = index(y_est))
  
  # Prediction of next periods unseen return
  mean_pred        <- predict(svm_mean, newdata = pred_data)
  
  
  #############################################################################
  # 2. Fit variance model
  #############################################################################
  
  # Set paramters
  svm_var_eps       <- quantile(scale(eps)^2, variance.mdl$eps_quantile)
  svm_var_cost      <- variance.mdl$cost
  sigma             <- variance.mdl$sigma
  svm_var_gamma     <- 1/(2*sigma^2)
  
  
  # Get data
  u                 <- na.omit(cbind(eps, lag(eps)))^2
                    
  # Data for variance prediction
  vola_pred_data    <- mean_pred[-length(mean_pred)] - pred_data[-1]
  
  
  # Estimate model 
  svm_var           <- svm_variance(x = u[,-1], y = u[,1], m = variance.mdl$model,
                                    gamma = svm_var_gamma, 
                                    cost = svm_var_cost, 
                                    epsilon = svm_var_eps)
  
  # Get fitted variances to standardize residuals
  if(variance.mdl$model == "AR")   fcast_vola <- svm_var$fitted
  if(variance.mdl$model == "ARMA") fcast_vola <- svm_var$model$fitted
  
  # Replace negativ variances by last positiv value
  fcast_vola[fcast_vola<=0] <- NA 
  fcast_vola                <- na.locf(fcast_vola)
  fcast_vola[1]             <- ifelse(is.na(fcast_vola[1]), u[1,2], fcast_vola[1])
  
  # Prediction of next periods unseen variance
  if(variance.mdl$model == "AR"){
    
    vola_new_dat <- u[nrow(u),1]
    vola_pred  <- predict(svm_var, newdata = vola_new_dat)
    
  }
  
  if(variance.mdl$model == "ARMA"){
    
    vola_new_dat <- cbind(u[nrow(u),1], svm_var$lagRes[length(svm_var$lagRes)]) 
    
    vola_pred     <- rep(0, (delta + 1))
    vola_pred[1]  <- predict(svm_var$model, newdata = vola_new_dat)
    
    for(vola_i in 2:length(vola_pred)){
      
      res                <- vola_pred_data[(vola_i-1)] - vola_pred[(vola_i-1)]
      vola_new_dat       <- cbind(vola_pred_data[(vola_i-1)], res)
      vola_pred[vola_i]  <- predict(svm_var$model, newdata = vola_new_dat)
      
    }
    
  }
  

  #############################################################################
  # 3. Compute quantiles of scaled standardized residuals
  #############################################################################
  
  # Standardize and scale residuals
  if(variance.mdl$model == "AR")   u_sc <- eps[-1]/sqrt(fcast_vola)
  if(variance.mdl$model == "ARMA") u_sc <- eps[-(1:2)]/sqrt(fcast_vola)
  
  u_sc             <- scale(u_sc)
  
  # Compute quantiles of scaled standardized residuals
  q_upper          <- QKDE(q, c(0, max(u_sc)*1.5), data = u_sc, kernel = kernel)
  q_lower          <- -QKDE(q, c(0, max(-u_sc)*1.5), data = -u_sc, kernel = kernel)
  
  
  #############################################################################
  # 4. Collect results
  #############################################################################
  
  # Specify data frame for storing results
  results          <- data.frame(matrix(NA, nrow = (delta + 1), ncol = 4))
  names(results)   <- c("Mean", "Upper", "Lower", "Vola")
  
  # Save results in data frame
  results$Mean     <- mean_pred
  results$Upper    <- q_upper
  results$Lower    <- q_lower
  results$Vola     <- ifelse(vola_pred <= 0, u[nrow(u),2], sqrt(vola_pred))
  
  return(results)
  
}



###############################################################################
# Function for variance estimation

svm_variance <- function(x, y, m, gamma, cost, epsilon){
  
  if(m == "AR"){
    
    model   <- svm(x = x, y = y, scale = TRUE,
                   type = "eps-regression", kernel = "radial",
                   gamma = gamma, cost = cost, epsilon = epsilon)
    
    result <- model
    
  }
  
  if(m == "ARMA"){
    
    rnn_v1   <- svm(x = x, y = y, scale = TRUE,
                    type = "eps-regression", kernel = "radial",
                    gamma = gamma, cost = cost, epsilon = epsilon)
    
    w           <- xts(x = rnn_v1$residuals, order.by = index(y))
    garch_input <- na.omit(cbind(y, x, lag(w)))
    
    model  <- svm(x = garch_input[,2:3], y = garch_input[,1], scale = TRUE, 
                  type = "eps-regression", kernel = "radial",
                  gamma = gamma, cost = cost, epsilon = epsilon)
    
    result <- list(model = model, lagRes = w)
    
  }
  
  
  
  return(result)
  
}

###############################################################################
# Mean model


svm_kde_mean <- function(x, y, mean_mdl){
  
  #############################################################################
  # 1. Fit mean model
  #############################################################################
  
  # Set parameters
  svm_mean_eps     <- mean_mdl$eps
  svm_mean_cost    <- mean_mdl$cost
  sigma            <- mean_mdl$sigma
  svm_mean_gamma   <- 1/(2*sigma^2)
  
  # SVM for mean
  svm_mean         <- svm(x = x, y = y, type = "eps-regression", kernel = "radial",
                          gamma = svm_mean_gamma,
                          cost = svm_mean_cost,
                          epsilon = svm_mean_eps)
  
  # Get fitted values and residual (format as xts for lagging in variance fitting)
  mean             <- xts(x = svm_mean$fitted, order.by = index(y))
  eps              <- xts(x = svm_mean$residuals, order.by = index(y))
  
  # Prediction of next periods unseen return
  mean_pred        <- predict(svm_mean, newdata = y[nrow(y)])
  
  return(mean_pred)
  
}

###############################################################################
# Mean model parallelized

svm_kde_mean_dopar <- function(data, block, test, mean_mdl){
  
  
  if(nrow(data) < block + test) stop("Number of rows in 'data' is less than block + test")
  
  source("C:/Users/Marius/Desktop/Master/Master_Thesis/Simulation/SVRGARCHKDE_Functions/Source_File/Source_SVRGARCHKDE.R")
  library(doParallel)
  library(quantmod)
  
  allData    <- data
  test_n     <- test 
  block_size <- block
  loop_start <- nrow(allData) - test_n
  loop_end   <- nrow(allData) - 1
  
  results    <- data.frame(Mean = numeric(),
                           Upper = numeric(),
                           Lower = numeric(),
                           Vola = numeric())
  
  cl <- makeCluster(4)
  registerDoParallel(cl)
  
  results <- foreach(i = loop_start:loop_end, .combine = "rbind") %dopar% {
    
    source("C:/Users/Marius/Desktop/Master/Master_Thesis/Simulation/SVRGARCHKDE_Functions/Source_File/Source_SVRGARCHKDE.R")
    library(quantmod)
    library(e1071)
    library(zoo)
    
    x            <- allData[(i-block_size+1):i,-1]
    y            <- allData[(i-block_size+1):i,1]
    mean_mdl     <- mean_mdl
    
    svm_kde_mean(x = x, y = y, mean_mdl = mean_mdl)
    
    
  }
  stopCluster(cl)
  
  real  <- data[(nrow(data) - test + 1):nrow(data),1]
  pred  <- xts(results, order.by = index(real))
  
  mse   <- sum((coredata(real) - coredata(pred))^2)/nrow(real)
  
  results <- mse
  
  return(results)
  
}

###############################################################################
# Function for plotting results and analysis

plotResults <- function(results, allData, test_n, q){
  
  
  results$True <- allData[(nrow(allData) - test_n + 1):nrow(allData),1]
  
  #Analyze Results
  
  results$FCast_Upper <- results$Mean + results$Upper*results$Vola
  results$FCast_Lower <- results$Mean + results$Lower*results$Vola
  
  prop_upper <- sum(results$FCast_Upper < results$True)/nrow(results)  #
  prop_lower <- sum(results$FCast_Lower > results$True)/nrow(results)  #Downside risk: if greater 5% -> BAD
  
  #Plot in-sample results
  org         <- as.numeric(results$True)
  fcast_upper <- results$FCast_Upper
  fcast_lower <- results$FCast_Lower
  
  ylim_max <- max(abs(c(org, fcast_upper, fcast_lower)))
  ylim_min <- -ylim_max
  
  head <- paste0(q*100, "% and ", (1-q)*100, "% VaR-Forecast")
  plot(results$True, type = "p", ylim = c(ylim_min, ylim_max), 
       ylab = "Return in Percent", main = head)
  points(results$True, col = "green")
  lines(xts(x = fcast_upper, order.by = index(results$True)), col = "red", lwd = 2)
  lines(xts(x = fcast_lower, order.by = index(results$True)), col = "red", lwd = 2)
  
  # plot(org, type = "p", col = "green", lwd = 1, ylim = c(ylim_min, ylim_max), ylab = "Value")
  # lines(fcast_upper, col = "red", lwd = 2)
  # lines(fcast_lower, col = "red", lwd = 2)
  errors <- data.frame(Index = 1:length(org), Real = org)
  out    <- errors$Real > fcast_upper | errors$Real < fcast_lower
  points(errors$Index[out], errors$Real[out], col = "blue", pch = 16)
  
  #print(prop_upper)
  #print(prop_lower)
  
  prop <- data.frame(prop_upper, prop_lower)
  
  results <- list(Data = results, 
                  Empirical_Coverage = prop)
  
  return(results)
  
}

###############################################################################
# VaR using kernel density estimation

KDE_VaR <- function(x, q, kernel){
  
  #############################################################################
  # 1. Estimate quantiles of data
  #############################################################################
  
  q_upper          <- QKDE(q, c(0, max(x)*1.5), data = x, kernel = kernel)
  q_lower          <- -QKDE(q, c(0, max(-x)*1.5), data = -x, kernel = kernel)
  
  
  #############################################################################
  # 2. Collect results
  #############################################################################
  
  # Specify data frame for storing results
  results          <- data.frame(matrix(NA, nrow = 1, ncol = 4))
  names(results)   <- c("Mean", "Upper", "Lower", "Vola")
  
  # Save results in data frame
  results$Mean     <- 0
  results$Upper    <- q_upper
  results$Lower    <- q_lower
  results$Vola     <- 1
  
  return(results)
  
}
