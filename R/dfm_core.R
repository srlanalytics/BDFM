# m <- 2
# p <- "auto"
# freq <- "auto"
# method = "bayesian"
# Bp <- NULL
# preD <- 1
# lam_B = 0
# trans_df = 0
# Hp = NULL
# lam_H = 0
# obs_df = NULL
# ID = "pc_long"
# store_idx = 1
# reps = 1000
# burn = 500
# verbose = T
# tol = .01
# FC = 3
# # logs = NULL
# # diffs = NULL
# logs = c( 2,  4,  5,  8,  9, 10, 11, 12, 15, 16, 17, 21, 22)
# diffs = c(2, 4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24)
# outlier_threshold <- 4
# scale = TRUE

dfm_core <- function(Y, m, p, FC, method, scale, logs, outlier_threshold, diffs, freq, preD,
                     Bp, lam_B, trans_df, Hp, lam_H, obs_df, ID,
                     store_idx, reps, burn, verbose, tol, return_intermediates) {

  #-------Data processing-------------------------

  k <- NCOL(Y) # number of series

  # frequency
  if (freq == "auto") {
    freq <- apply(Y, MARGIN = 2, FUN = get_freq)
  } else if (!is.integer(freq) || length(freq) != ncol(Y)) {
    stop("Argument 'freq' must be 'auto' or integer valued with
         length equal to the number data series")
  }

  if (p == "auto"){
    p <- max(freq)
  }

  if (FC == "auto"){
    FC <- max(freq)
  }

  # add forecast periods
  if (FC > 0) {
    tmp <- matrix(NA, FC, k)
    Y <- rbind(Y, tmp)
  }

  # logs
  if (!is.null(logs)) {
    logs <- standardize_index(logs, Y)
    Y[, logs] <- log(Y[, logs])
  }

  # differences
  if (!is.null(diffs)) {
    Y_lev <- Y
    diffs <- standardize_index(diffs, Y)
    Y[, diffs] <- sapply(diffs, mf_diff, fq = freq, Y = Y)
  }

  # if (!is.null(trans_df)) {
  #   trans_df <- standardize_index(trans_df, Y)
  # }

  if (!is.null(obs_df)) {
    obs_df <- standardize_numeric(obs_df, Y)
  }

  # specify which series are differenced for mixed frequency estimation

  LD <- rep(0, NCOL(Y))
  if (!is.null(preD)) {
    preD <- standardize_index(preD, Y)
  }
  LD[unique(c(preD, diffs))] <- 1 # in bdfm 1 indicates differenced data, 0 level data

  # drop outliers
  Y[abs(scale(Y)) > outlier_threshold] <- NA

  if (scale) {
    Y <- 100*scale(Y)
    y_scale  <- attr(Y, "scaled:scale")
    y_center <- attr(Y, "scaled:center")
  }

  if (!is.null(store_idx)){
    if(length(store_idx)>1){
      stop("Length of 'store_idx' cannot be greater than 1")
    }
    store_idx <- standardize_index(store_idx, Y)
  }

  if(!ID%in%c("pc_full", "pc_sub", "pc_long", "name")){
    ID <- standardize_index(ID, Y)
  }
  
  if (length(unique(freq)) != 1 && method != "bayesian") {
    stop("Mixed freqeuncy models are only supported for Bayesian estimation")
  }

  if (method == "bayesian") {
    est <- bdfm(
      Y = Y, m = m, p = p, Bp = Bp,
      lam_B = lam_B, Hp = Hp, lam_H = lam_H, nu_q = trans_df, nu_r = obs_df,
      ID = ID, store_idx = store_idx, freq = freq, LD = LD, reps = reps,
      burn = burn, verbose = verbose
    )
  } else if (method == "ml") {
    est <- MLdfm(
      Y = Y, m = m, p = p, tol = tol,
      verbose = verbose
    )
  } else if (method == "pc") {
    est <- PCdfm(
      Y, m = m, p = p, Bp = Bp,
      lam_B = lam_B, Hp = Hp, lam_H = lam_H, nu_q = trans_df, nu_r = obs_df,
      ID = ID, reps = reps, burn = burn
    )
  }
  
  
  #Get forecast updates at each period
  factor_update <- lapply(X = seq(to = NROW(Y)), FUN = factor_updates, gain = lapply(est$Kstore, one_through_m, m = m), PE = est$PEstore)
  factor_update <- lapply(X = seq(to = NROW(Y)), FUN = name_updates, Y = Y, fc_update = factor_update) #name updates
  est$Kstore  <- NULL #this is huge and no longer needed, so drop it
  est$PEstore <- NULL #this is huge and no longer needed, so drop it
  est$factor_update <- factor_update #return this instead --- far more useful!

  # undo scaling
  if(scale){
    est$values <- (matrix(1, nrow(est$values), 1) %x% t(y_scale)) * (est$values / 100) + (matrix(1, nrow(est$values), 1) %x% t(y_center))
    est$R2     <- 1 - est$R/10000
    if(!is.null(store_idx) && method == "bayesian"){
      est$Ystore <- est$Ystore*(y_scale[store_idx]/100) + y_center[store_idx]
      est$Ymedain <- est$Ymedian*(y_scale[store_idx]/100) + y_center[store_idx]
    }
  }else{
    est$R2 <- 1 - est$R/apply(X = Y, MARGIN = 2, FUN = var, na.rm = TRUE)
  }
  
  # get updates to store_idx if specified
  if(!is.null(store_idx)){
    if(scale){
      est$idx_update <- lapply(factor_update, FUN = multiply_each, loading = t(est$H[store_idx,,drop=FALSE]), y_scale = y_scale[store_idx]/100)
    }else{
      est$idx_update <- lapply(factor_update, FUN = multiply_each, loading = t(est$H[store_idx,,drop=FALSE]), y_scale = 1)
    }
  }

  # undo differences
  if (!is.null(diffs)) {
    est$values[,diffs] <- sapply(diffs, FUN = level, fq = freq, Y_lev = Y_lev, vals = est$values)
    if(!is.null(store_idx) && method == "bayesian" && store_idx%in%diffs){
      est$Ymedain <- level_simple(est$Ymedain, y_lev = Y_lev[,store_idx], fq = freq[store_idx])
      est$Ystore  <- apply(est$Ystore, MARGIN = 2, FUN = level_simple, y_lev = Y_lev[,store_idx], fq = freq[store_idx])
    }
  }

  # undo logs
  if (!is.null(logs)) {
    est$values[,logs] <- exp(est$values[,logs])
    if(!is.null(store_idx) && method == "bayesian" && store_idx%in%logs){
      est$Ymedain <- exp(est$Ymedain)
      est$Ystore  <- exp(est$Ystore)
    }
  }
  
  if (length(unique(freq))>1 && !return_intermediates){
    est$values[,which(freq != 1)] <- do.call(cbind, lapply(X = which(freq != 1), FUN = drop_intermediates, 
                                                           freq = freq, Y_raw = Y, vals = est$values))
  }

  return(est)
}