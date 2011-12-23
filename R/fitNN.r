fitNN <- function(x, groups, patterns, B=20, trace=TRUE) {
  require(EBarrays)
  if (is(x, "exprSet") | is(x, "ExpressionSet")) {
    if (is.character(groups) && length(groups) == 1) {
      groups <- as.factor(pData(x)[, groups])
    }
    x <- exprs(x)
  }
  else if (!is(x, "data.frame") & !is(x, "matrix")) {
      stop("x must be an ExpressionSet, exprSet, data.frame or matrix")
  }
  #Patterns
  K <- length(unique.default(groups))
  if (missing(patterns)) {
    patterns <- rbind(rep(0, K), 0:(K - 1))
    colnames(patterns) <- unique.default(groups)
  }
  #groupsr <- groups2int(groups, patterns) + 1
  if (length(unique(groups)) != ncol(patterns)) stop("patterns must have the same number of columns as the number of distinct groups")
  if (ncol(patterns) != K) stop("patterns must have number of columns equal to the number of distinct elements in groups")
  if (sum(is.na(patterns)) > 0) stop("patterns cannot have any NA values")
  if (sum(is.nan(patterns)) > 0) stop("patterns cannot have any NaN values")
  if (sum(is.infinite(patterns)) > 0) stop("patterns cannot have any Inf values")
  for (i in 1:nrow(patterns)) { patterns[i, ] <- as.integer(as.integer(as.factor(patterns[i,])) - 1) }
  class(patterns) <- "gagahyp"
  hypotheses <- makeEBarraysHyp(patterns=patterns, groups=groups)
  #Fit model
  expx <- exp(x)
  verbose <- getOption("verbose")
  options(verbose=trace)
  family <- eb.createFamilyLNNMV()
  nn.fit <- emfit(data=expx, family=family, hypotheses=hypotheses, groupid=groups, num.iter=B)
  options(verbose=verbose)
  priorest <- sigmaPriorEst(x=x,groupid=groups,model='NN')
  pp <- postprob(fit=nn.fit, data=expx, groupid=groups)$pattern
  #Return output
  parest <- c(mu0=nn.fit@thetaEst[1,'theta1'],tau02=exp(nn.fit@thetaEst[1,'theta2']),priorest['v0'],priorest['sigma02'],probclus=1,probpat=nn.fit@probEst)
  ans <- list(parest=parest, patterns=patterns, pp=pp, nn.fit=nn.fit)
  class(ans) <- 'nnfit'
  return(ans)
}



sigmaPriorEst <- function(x, groupid, model='LNN') {
#Estimate sigma_j^2 ~ IG(.5*v0,.5*v0*sigma0^2) prior LNN & NN models via Method of Moments (as in package EBarrays)
  if (is(x, "ExpressionSet")) x <- exprs(x)
  if (model=='LNN') { x <- log(x) } else if (model!='NN') { stop('model not recognized') }
  n <- sum(groupid != 0)
  groups <- unique(groupid)
  groups <- groups[groups != 0]
  ngroup <- length(groups)
  vars <- 0
  for (i in 1:ngroup) {
    temp <- x[, groupid == groups[i]]
    ncoltemp <- sum(groupid == groups[i])
    if (ncoltemp == 1) { vars <- vars } else { vars <- vars + (ncoltemp - 1) * apply(temp, 1, FUN = var) }
  }
  svars <- vars/(n - ngroup)
  v0 <- mean(svars)^2/((length(svars) - 1)/length(svars) * var(svars)) * 2 + 4
  sigma02 <- mean(svars) * (v0 - 2)/v0
  return(c(v0=v0,sigma02=sigma02))
}

#Format patterns & groups information into ebarraysPatterns object. Used to call EBarrays routines
makeEBarraysHyp <- function(patterns, groups) {
hypotheses <- character(nrow(patterns))
for (i in 1:nrow(patterns)) {
  tmp <- integer(length(groups))
  for (j in unique(patterns[i,])) tmp[groups %in% colnames(patterns)[patterns[i,]==j]] <- j+1
  hypotheses[i] <- paste(tmp,collapse=' ')
}
  ebPatterns(hypotheses)
}



#routine to adjust bias
adjustfitNN <- function(fit, pitrue, mc.cores=1) {
  if (class(fit)!='nnfit') stop('fit should be of class nnfit')
  if (ncol(fit$patterns)>2) stop('Only 2 patterns case is currently implemented')
  f <- function(pitrue,pars,B=3) {
    tau0 <- sqrt(pars['tau02'])
    sigma0 <- sqrt(pars['sigma02'])
    ans <- double(B)
    for (i in 1:B) {
      xsim <- simNN(n=nrow(x),m=c(3,2),p.de=pitrue,mu0=pars['mu0'],tau0=tau0,v0=pars['v0'],sigma0=sigma0)
      fit <- fitNN(xsim,group=group,trace=FALSE)
      ans[i] <- getpar(fit)['probpat2']
    }
    return(mean(ans))
  }
  #Obtain expected estimate for a series of true parameter values
  probpatObs <- getpar(fit)['probpat2']
  if (missing(pitrue)) { pitrue <- seq(probpatObs/3,probpatObs,length=10) }
  if (mc.cores>1) {
    if ('multicore' %in% loadedNamespaces()) {
      probpatExpect <- mclapply(pitrue,f,pars=getpar(fit),B=3,mc.cores=mc.cores)
    } else stop('multicore library has not been loaded!')
  } else {
    probpatExpect <- lapply(pitrue,f,pars=getpar(fit),B=3)
  }
  probpatExpect <- unlist(probpatExpect)
  #True probpat as a smooth function of the estimated probpat
  require(mgcv)
  gam1 <- gam(pitrue ~ s(probpatExpect))
  newdata <- data.frame(probpatExpect=seq(min(probpatExpect),max(probpatExpect),length=1000))
  newdata$pitrue <- predict(gam1,newdata=newdata)
  probpatAdj <- newdata$pitrue[which.min(abs(newdata$probpatExpect-probpatObs))]
  #Return answer
  probpat <- data.frame(truth=pitrue,expected=probpatExpect)
  fit$pp <- t((t(fit$pp)/fit$parest[c('probpat1','probpat2')]) * c(1-probpatAdj,probpatAdj))
  fit$pp <- fit$pp/rowSums(fit$pp)
  fit$parest[c('probpat1','probpat2')] <- c(1-probpatAdj,probpatAdj)
  ans <- list(fit=fit,probpat=probpat)
  return(ans)
}
