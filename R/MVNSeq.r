#' Hidden Markov and Mixture models for sequences of multivariate
#' Normal observations.
#'
#' Provides facilities for fitting hidden Markov and mixture models to
#' sequences of multivariate Normal observations.  Allows for multiple
#' sequences and random variation in the state means across different
#' sequences.
#'
#' @name MVNSeq-package
#' @docType package
#' @author S. Wotherspoon, A. Bindoff.
NULL





################################################################################
## Model parameters
##
## Mixture models
## For mixture models the parameters are stored as a list with
## components
##
## K    - number of components in mixture
## p    - vector of K mixing fractions
## mvn  - list of length K where kth element is a list of the mean
##        and variance for component k
## and optionally
## P    - n x K array of posterior class memberships
## logL - log likelihood for the mixture.
##
##
## Hidden Markov models
## For hidden markov models the parameters are stored as a list with
## components
##
## K    - number of states
## p   - prior probabilities for the initial state
## Q    - transition matrix
## mvn  - list of length K where kth element is a list of the mean
##        and variance for component k
## and optionally
## Q0   - expected joint probabilities
## P    - n x K array of posterior class memberships
## logL - log likelihood for the mixture.
##
##
## Random effects
## Random effects models also store a list with components
##
## mu   - overall mean
## U    - covariance of random effects
## V    - error covariance


##' Initial parameter estimates for HMM and mixture models.
##'
##' Given a sequence of observations and a vector of initial class
##' allocations, estimate the parameters for a mixture or hidden
##' Markov model.
##'
##' @title Initial Parameters
##' @param y the sequence of observations
##' @param cl an integer vector allocating observations to classes
##' @param K the number of classes
##' @return \code{parsMixClass} returns a list with elements
initMix <- function(y,cl,K=max(cl)) {
  ## Component means and variances
  mvn <- lapply(1:K,function(k) {
    yk <- y[cl==k,,drop=F]
    list(mu=colMeans(yk),Sigma=cov(yk))
  })

  ## Return parameters
  list(K=K,mvn=mvn,p=tabulate(cl)/length(cl))
}

##' @rdname initMix
initHMM <- function(y,cl,K=max(cl)) {
  r <- initMix(y,cl,K)
  n <- length(cl)
  r$Q0 <- table(cl[-n],cl[-1])/(n-1)
  r$Q <- r$Q0/rowSums(r$Q0)

  r
}


##' Initial parameter estimates for random effect HMM and mixture models
##'
##' Estimates the random effects parameters from lists of mixture or
##' hidden Markov parameters.
##'
##' @title Initial Parameters
##' @param K the number of classes
##' @param pars lists of parameters generated by \code{initMix} or \code{initHMM}
##' @return the estimated parameters
initGroup <- function(K,pars) {
  muv <- structure(vector(mode="list",K),class="rcpars")
  ## Estimate population parameters from group parameters
  for(k in 1:K) {
    mus <- t(sapply(pars,function(par) par$mvn[[k]]$mu))
    V <- sapply(pars,function(par) par$mvn[[k]]$Sigma,simplify="array")
    V <- if(!is.null(dim(V))) apply(V,1:2,mean) else matrix(mean(V),1,1)
    muv[[k]] <- list(mu=colMeans(mus),U=cov(mus),V=V)
    for(g in seq_along(pars)) pars[[g]]$mvn[[k]]$Sigma <- V
  }
  list(muv=muv,pars=pars)
}


##' Initial parameter estimates for two state HMM model with variable
##' transition probabilities
##'
##' Given a sequence of observations and a vector of initial class
##' allocations, estimate the parameters for a two state hidden Markov
##' model where the transition probabilities are governed by logistic
##' regression.
##'
##' @title Initial Parameters
##' @param y the sequence of observations
##' @param cl an integer vector allocating observations to classes
##' @param formula1 formula for the logistic model relating the transition from state 1 to state 2 to the covariates
##' @param formula2 formula for the logistic model relating the transition from state 2 to state 1 to the covariates
##' @param data a dataframe of covariates
##' @return estimated model parameters
initHMM2 <- function(y,cl,formula1,formula2,data) {

  K <- 2
  ## Component means and variances
  mvn <- lapply(1:K,function(k) {
    yk <- y[cl==k,,drop=F]
    list(mu=colMeans(yk),Sigma=cov(yk))
  })

  n <- length(cl)
  Q <- table(cl[-n],cl[-1])/(n-1)
  Ps <- array(Q,c(2,2,n-1))

  w <- Ps[1,1,]+Ps[1,2,]
  q <- Ps[1,1,]/(w+1.0E-6)
  X <- model.matrix(formula1,data=data[-n,])
  fit <- suppressWarnings(glm.fit(X,q,weights=w,family=binomial()))
  beta1 <- coef(fit)
  q1 <- fitted(fit)

  w <- Ps[2,1,]+Ps[2,2,]
  q <- Ps[2,2,]/(w+1.0E-6)
  X <- model.matrix(formula2,data=data[-n,])
  fit <- suppressWarnings(glm.fit(X,q,weights=w,family=binomial()))
  beta2 <- coef(fit)
  q2 <- fitted(fit)

  ## Return parameters
  list(K=K,p=tabulate(cl)/length(cl),
       beta1=beta1,q1=q1,beta2=beta2,q2=q2,mvn=mvn)
}




################################################################################
## EM - Multivariate Normal
## The following functions perform those steps of the EM algorithm
## associated with fitting the multivariate Normal components


##' The multivariate Normal update step of the EM algorithm.
##'
##' Perform a single step of the EM algorithm
##' fitting a mean and covariance for each component.
##'
##' @title MVN EM Update
##' @param K the number of classes
##' @param y the sequence of observations
##' @param ys the list of sequences of observations
##' @param pars current sequence parameters
##' @param muv current population parameters
##' @return the updated set of parameters
mvnEMStep <- function(K,y,pars) {
  for(k in 1:K) {
    ## Weight by membership probabilities
    w <- pars$P[,k]
    wsum <- sum(w)
    mu <- colSums(w*y)/wsum
    r <- y-rep(1,nrow(y))%o%mu
    Sigma <- crossprod(sqrt(w)*r)/wsum
    pars$mvn[[k]] <- list(mu=mu,Sigma=Sigma)
  }
  pars
}

##' @rdname mvnEMStep
gmvnEMStep <- function(K,ys,pars) {
  ## Update means and record contributions to covariance update
  for(k in 1:K) {
    SS <- W <- 0
    for(g in seq_along(ys)) {
      ## Extract data for this group
      y <- ys[[g]]
      mvn <- pars[[g]]$mvn
      ## Weight by membership probabilities
      w <- pars[[g]]$P[,k]
      wsum <- sum(w)
      mu <- colSums(w*y)/wsum
      r <- y-rep(1,nrow(y))%o%mu
      ## Sums of squares and weights for common covariance
      SS <- SS+crossprod(sqrt(w)*r)
      W <- W+wsum
      pars[[g]]$mvn[[k]]$mu <- mu
    }
    SS <- SS/W
    for(g in seq_along(ys)) pars[[g]]$mvn[[k]]$Sigma <- SS
  }
  pars
}

##' @rdname mvnEMStep
grmvnEMStep <- function(K,ys,pars,muv) {
  for(k in 1:K) {
    mu <- muv[[k]]$mu
    U.inv <- solve(muv[[k]]$U)
    V.inv <- solve(muv[[k]]$V)
    ## Expected sufficient statistics
    W <- S.a <- SS.a <- SS.err <- 0
    for(g in seq_along(ys)) {
      y <- ys[[g]]
      w <- pars[[g]]$P[,k]
      ysum <- colSums(w*y)
      wsum <- sum(w)
      ybar <- ysum/wsum
      yerr <- y-rep(1,nrow(y))%o%ybar
      var.a <- solve(U.inv + wsum*V.inv)
      mu.a <- mu+drop(var.a%*%V.inv%*%(ysum-wsum*mu))
      W <- W + wsum
      S.a <- S.a + mu.a
      SS.a <- SS.a+(mu.a-mu)%o%(mu.a-mu)+var.a
      SS.err <- SS.err + crossprod(sqrt(w)*yerr)+wsum*((ybar-mu.a)%o%(ybar-mu.a)+var.a)
      pars[[g]]$mvn[[k]]$mu <- mu.a
    }
    muv[[k]] <- list(mu=S.a/length(ys),U=SS.a/length(ys),V=SS.err/W)
    for(g in seq_along(ys)) pars[[g]]$mvn[[k]]$Sigma <- muv[[k]]$V
  }
  list(muv=muv,pars=pars)
}




################################################################################
## EM - Mixture and HMM
## The following functions perform those steps of the EM algorithm
## associated with fitting the mixture or hidden Markov model


##' The mixture update step of the EM algorithm.
##'
##' Perform a single step of the EM algorithm to fit the mixture
##' component of a multivariate Normal mixture model.
##'
##' @title Mixture EM Update
##' @param K the number of classes
##' @param y the sequence of observations
##' @param pars current sequence parameters
##' @return the updated set of parameters
##' @importFrom mvtnorm dmvnorm
mixEMStep <- function(K,y,pars) {

  mvn <- pars$mvn
  p <- pars$p

  ## Likelihood for each class
  L <- matrix(0,nrow(y),K)
  for(k in 1:K) L[,k] <- dmvnorm(y,mvn[[k]]$mu,mvn[[k]]$Sigma)

  ## Posterior probability of class membership (Bayes rule)
  P <- L%*%diag(p)
  P <- P/rowSums(P)

  ## Mixing fractions
  p <- colMeans(P)

  ## Contribution to the log likelihood
  logL <- sum(log(L%*%p))

  structure(list(K=K,mvn=mvn,p=p,P=P,logL=logL),
            class="mixpars")
}


## HMM Forward Backward Recursions
## Implement the forward backward recursion for HMM's as described by
## Scott(2002).  Our notation differs a little from Scott's.
## The transition matrix Q for the underlying chain is the matrix with
## elements q_{ij} such that
##
##      q_{ij} = P( s_{k+1}=j | s_{k}=i )
##
## The algorithm computes for each transition the matrix P of joint
## probabilities,
##
##      p_{ij} = P( s_{k+1}=j , s_{k}=i )
##
## and the corresponding marginals ps.



##' The HMM update step of the EM algorithm.
##'
##' Perform a single step of the EM algorithm to fit the HMM component
##' of a multivariate Normal HMM model.
##'
##' @title HMM EM Update
##' @param K the number of classes
##' @param y the sequence of observations
##' @param pars current sequence parameters
##' @return the updated set of parameters
##' @importFrom mvtnorm dmvnorm
hmmEMStep <- function(K,y,pars) {

  ## Extract data for this group
  mvn <- pars$mvn
  p <- pars$p
  Q <- pars$Q
  n <- nrow(y)

  ## Array of joint probabilites
  Ps <- array(0,c(K,K,n-1))
  ## Array of marginal probabilities
  ps <- array(0,c(K,n))
  ## Array of response probabilities
  logF <- matrix(0,n,K)

  ## logF[i,j] = log p(y_{i}|s_{i}=j)
  for(j in 1:K)
    logF[,j] <- dmvnorm(y,mvn[[j]]$mu,mvn[[j]]$Sigma,log=T)

  ## logf[i] = log p(y_{1}|s_{1}=i)
  logf <- logF[1,]
  ## p[i]=p(y_{1},s_{1}=i)
  p <- p*exp(logf)
  ## logL= \sum_i p(Y_{1},s_{1}=i) p(s_{1}=i)
  logL <- log(sum(p))
  ## p[i]=p(s_{1}=i | y_{1})
  p <- p/sum(p)

  ## Forward recursion
  for(k in 1:(n-1)) {
    ## logf[i] = log p(y_{k+1}|s_{k+1}=i)
    logf <- logF[k+1,]
    ## P[i,j] = p(y_{k+1},s_{k+1}=j,s_{k}=i| Y_{k})
    P <- Q*(p%o%exp(logf))
    ## P[i,j] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    P <- P/sum(P)

    ## Log likelihood increment
    ## logl[i]=log p(y_{k} | s_{k}=i) + \log \sum_{s_{k-1}} p(s_{k}=i|s_{k-1})p(s_{k-1} | Y_{k-1})
    l <- logf+log(p%*%Q)
    M <- max(l)
    logL <- logL+M+log(sum(exp(l-M)))

    ## p[i] = p(s_{k+1}=i| Y_{k+1})
    p <- colSums(P)
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    Ps[,,k] <- P
  }
  ## ps[i,n] = p(s_{n}=i| Y_{n})
  ps[,n] <- p

  ## Backward recursion
  for(k in (n-2):1) {
    ## p[i] = p(s_{k+1}=i | Y_{n})
    p <- rowSums(P)
    ## ps[i,k+1] = p(s_{k+1}=i| Y_{n})
    ps[,k+1] <- p
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    P <- Ps[,,k]
    ## q[i] = p(s_{k+1}=i | Y_{n}) / p(s_{k+1}=i | Y_{k+1})
    ## Must be careful to avoid a divide by 0 error.
    q <- ifelse(p==0,0,p/colSums(P))
    ## P[i,j] = p(s_{k+1}=j,s_{k}=i| Y_{k+1}) [p(s_{k+1}=i | Y_{n}) / p(s_{k+1}=i | Y_{k+1})]
    P <- P*(rep(1,K)%o%q)
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{n})
    Ps[,,k] <- P
  }
  ## p[i] = p(s_{1}=i | Y_{n})
  p <- rowSums(P)
  ## ps[i,1] = p(s_{1}=i| Y_{n})
  ps[,1] <- p


  ## M step - update Q, p
  Q0 <- apply(Ps,1:2,mean)
  Q <- Q0/rowSums(Q0)
  p <- rowMeans(ps)

  structure(list(K=K,mvn=mvn,p=p,P=t(ps),Q=Q,Q0=Q0,logL=logL),
            class="hmmpars")
}



##' The HMM update step of the EM algorithm
##'
##' Perform a single step of the EM algorithm to fit the HMM component
##' of a two state multivariate Normal HMM model where the transistion
##' probabilities are governed by logistic regression models.
##'
##' @title HMM EM Update
##' @param K the number of classes
##' @param y the sequence of observations
##' @param pars current sequence parameters
##' @param formula1 formula for the logistic model relating the transition from state 1 to state 2 to the covariates
##' @param formula2 formula for the logistic model relating the transition from state 2 to state 1 to the covariates
##' @param data a dataframe of covariates
##' @return the updated set of parameters
##' @importFrom mvtnorm dmvnorm
hmm2EMStep <- function(K,y,pars,formula1,formula2,data) {

  ## Extract data for this group
  mvn <- pars$mvn
  p <- pars$p
  n <- nrow(y)

  Q <- array(0,c(2,2,n-1))
  Q[1,1,] <- pars$q1
  Q[1,2,] <- 1-pars$q1
  Q[2,2,] <- pars$q2
  Q[2,1,] <- 1-pars$q2


  ## Array of joint probabilites
  Ps <- array(0,c(K,K,n-1))
  ## Array of marginal probabilities
  ps <- array(0,c(K,n))
  ## Array of response probabilities
  logF <- matrix(0,n,K)

  ## logF[i,j] = log p(y_{i}|s_{i}=j)
  for(j in 1:K)
    logF[,j] <- dmvnorm(y,mvn[[j]]$mu,mvn[[j]]$Sigma,log=T)

  ## logf[i] = log p(y_{1}|s_{1}=i)
  logf <- logF[1,]
  ## p[i]=p(y_{1},s_{1}=i)
  p <- p*exp(logf)
  ## logL= \sum_i p(Y_{1},s_{1}=i) p(s_{1}=i)
  logL <- log(sum(p))
  ## p[i]=p(s_{1}=i | y_{1})
  p <- p/sum(p)

  ## Forward recursion
  for(k in 1:(n-1)) {
    ## logf[i] = log p(y_{k+1}|s_{k+1}=i)
    logf <- logF[k+1,]
    ## P[i,j] = p(y_{k+1},s_{k+1}=j,s_{k}=i| Y_{k})
    P <- Q[,,k]*(p%o%exp(logf))
    ## P[i,j] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    P <- P/sum(P)

    ## Log likelihood increment
    ## logl[i]=log p(y_{k} | s_{k}=i) + \log \sum_{s_{k-1}} p(s_{k}=i|s_{k-1})p(s_{k-1} | Y_{k-1})
    l <- logf+log(p%*%Q[,,k])
    M <- max(l)
    logL <- logL+M+log(sum(exp(l-M)))

    ## p[i] = p(s_{k+1}=i| Y_{k+1})
    p <- colSums(P)
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    Ps[,,k] <- P
  }
  ## ps[i,n] = p(s_{n}=i| Y_{n})
  ps[,n] <- p

  ## Backward recursion
  for(k in (n-2):1) {
    ## p[i] = p(s_{k+1}=i | Y_{n})
    p <- rowSums(P)
    ## ps[i,k+1] = p(s_{k+1}=i| Y_{n})
    ps[,k+1] <- p
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{k+1})
    P <- Ps[,,k]
    ## q[i] = p(s_{k+1}=i | Y_{n}) / p(s_{k+1}=i | Y_{k+1})
    ## Must be careful to avoid a divide by 0 error.
    q <- ifelse(p==0,0,p/colSums(P))
    ## P[i,j] = p(s_{k+1}=j,s_{k}=i| Y_{k+1}) [p(s_{k+1}=i | Y_{n}) / p(s_{k+1}=i | Y_{k+1})]
    P <- P*(rep(1,K)%o%q)
    ## Ps[i,j,k] = p(s_{k+1}=j,s_{k}=i| Y_{n})
    Ps[,,k] <- P
  }
  ## p[i] = p(s_{1}=i | Y_{n})
  p <- rowSums(P)
  ## ps[i,1] = p(s_{1}=i| Y_{n})
  ps[,1] <- p


  ## M step - update Q, p
  p <- rowMeans(ps)

  w <- Ps[1,1,]+Ps[1,2,]
  q <- Ps[1,1,]/(w+1.0E-6)
  X <- model.matrix(formula1,data=data[-n,])
  fit <- suppressWarnings(glm.fit(X,q,weights=w,family=binomial()))
  beta1 <- coef(fit)
  q1 <- fitted(fit)

  w <- Ps[2,1,]+Ps[2,2,]
  q <- Ps[2,2,]/(w+1.0E-6)
  X <- model.matrix(formula1,data=data[-n,])
  fit <- suppressWarnings(glm.fit(X,q,weights=w,family=binomial()))
  beta2 <- coef(fit)
  q2 <- fitted(fit)

  ## Return parameters
  list(K=K,
       mvn=mvn,
       p=p,
       beta1=beta1,q1=q1,
       beta2=beta2,q2=q2,
       P=t(ps),logL=logL)
}




##' Fit multivariate Normal mixture models by EM.
##'
##' These functions fit K component multivariate Normal mixtures to
##' sequences of observations. \code{mvnMix} fits a mixture model to a
##' single sequence of observations. \code{gmvnMix} and
##' \code{grmvnMix} fits separate mixture models to several groups
##' (sequences) of observations. \code{gmvnMix} fits a mixture to each
##' group so that each component has a different mean across groups,
##' but a common covariance. \code{grmvnMix} constrains the means of
##' the components to be Normally distributed across groups.
##'
##' @title Multivariate Normal Mixture Models
##' @param y the sequence of observations
##' @param cl an integer vector allocating observations to classes
##' @param gr an integer vector allocating observations to groups
##' @param min.iters minimum number of EM iterations
##' @param max.iters maximum number of EM iterations
##' @param tol tolerance for the log likelihood
##' @param common.fractions should the mixing fractions be common across groups
##' @param verbose should the log likelihood be reported.
##' @return the fitted model
##' @export
mvnMix <- function(y,cl,min.iters=10,max.iters=50,tol=1.0E-3,
                   verbose=interactive()) {

  K <- max(cl)
  pars <- initMix(y,cl)

  ## Initialize
  logL <- logL0 <- -Inf
  iter <- 0
  str <- ""

  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    pars <- mixEMStep(K,y,pars)
    logL <- pars$logL
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- mvnEMStep(K,y,pars)
  }
  ## Number of parameters
  q <- ncol(y)
  n.frac <- K-1
  n.mean <- K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.frac+n.mean+n.cov
  ## Return parameters with AIC/BIC
  structure(list(K=K,
                 pars=pars,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams),
            class="mvnmix")
}

##' @rdname mvnMix
##' @export
gmvnMix <- function(y,cl,gr,
                    common.fractions=FALSE,
                    min.iters=10,max.iters=50,tol=1.0E-3,
                    verbose=interactive()) {

  K <- max(cl)
  ys <- split.data.frame(y,gr)
  cls <- split(cl,gr)
  pars <- mapply(initMix,y=ys,cl=cls,
                 MoreArgs=list(K=K),
                 SIMPLIFY=FALSE)
  pars <- initGroup(K,pars)$pars

  ## Weights for common mixing fractions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    p <- 0
    for(g in seq_along(ys)) {
      ## Fit mixture for this group
      pars[[g]] <- mixEMStep(K,ys[[g]],pars[[g]])
      p <- p+ws[g]*pars[[g]]$p
    }

    ## Enforce common mixing fractions
    if(common.fractions) {
      for(g in seq_along(ys)) {
        pars[[g]]$p <- p
      }
    }

    ## Total log likelihood
    logL <- sum(sapply(pars,"[[","logL"))
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- gmvnEMStep(K,ys,pars)

  }
  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.frac <- (if(common.fractions) 1 else n.grp)*(K-1)
  n.mean <- n.grp*K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.frac+n.grp*n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  structure(list(K=K,
                 pars=pars,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams,
                 common.fractions=common.fractions),
            class="gmvnmix")
}



##' @rdname mvnMix
##' @export
grmvnMix <- function(y,cl,gr,
                     common.fractions=FALSE,
                     min.iters=10,max.iters=100,tol=1.0E-3,
                     verbose=interactive()) {

  K <- max(cl)
  ys <- split.data.frame(y,gr)
  cls <- split(cl,gr)
  pars <- mapply(initMix,y=ys,cl=cls,
                 MoreArgs=list(K=K),
                 SIMPLIFY=FALSE)
  fit <- initGroup(K,pars)
  pars <- fit$pars
  muv <- fit$muv

  ## Weights for common mixing fractions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    p <- 0
    for(g in seq_along(ys)) {
      ## Fit mixture for this group
      pars[[g]] <- mixEMStep(K,ys[[g]],pars[[g]])
      p <- p+ws[g]*pars[[g]]$p
    }

    ## Enforce common mixing fractions
    if(common.fractions) {
      for(g in seq_along(ys)) {
        pars[[g]]$p <- p
      }
    }

    ## Total log likelihood
    logL <- 0
    for(g in seq_along(ys)) {
      logL <- logL + pars[[g]]$logL
      for(k in 1:K)
        logL <- logL+dmvnorm(pars[[g]]$mvn[[k]]$mu,muv[[k]]$mu,muv[[k]]$U,log=T)
    }
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means, random effects and covariances
    fit <- grmvnEMStep(K,ys,pars,muv)
    pars <- fit$pars
    muv <- fit$muv
  }

  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.frac <- (if(common.fractions) 1 else n.grp)*(K-1)
  n.mean <- K*q
  n.cov <- 2*K*q*(q+1)/2
  nparams <- n.frac+n.grp*n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  structure(list(K=K,
                 pars=pars,
                 muv=muv,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams,
                 common.fractions=common.fractions),
            class="grmvnmix")
}




##' Fit multivariate Normal Hidden Markov models by EM.
##'
##' These functions fit K state multivariate Normal hidden Markov
##' models to sequences of observations. \code{mvnHMM} fits a hidden
##' Markov model to a single sequence of observations. \code{gmvnHMM}
##' and \code{grmvnHMM} fits separate Markov models to several groups
##' (sequences) of observations. \code{gmvnHMM} fits a hidden Markov
##' model to each group so that each state has a different mean across
##' groups, but a common covariance. \code{grmvnMix} constrains the
##' means of the states to be Normally distributed across groups.
##'
##' @title Multivariate Normal Mixture Model
##' @param y the sequence of observations
##' @param cl an integer vector allocating observations to classes
##' @param gr an integer vector allocating observations to groups
##' @param common.transition should the transition probabilities be common across groups
##' @param min.iters minimum number of EM iterations
##' @param max.iters maximum number of EM iterations
##' @param tol tolerance for the log likelihood
##' @param verbose should the log likelihood be reported.
##' @return the fitted model
##' @export
mvnHMM <- function(y,cl,min.iters=10,max.iters=50,tol=1.0E-3,
                   verbose=interactive()) {


  K <- max(cl)
  n <- nrow(y)
  pars <- initHMM(y,cl)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Fit HMM
    pars <- hmmEMStep(K,y,pars)
    logL <- pars$logL

    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- mvnEMStep(K,y,pars)
  }
  ## Number of parameters
  q <- ncol(y)
  n.prior <- K-1
  n.trans <- K*(K-1)
  n.mean <- K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.prior+n.trans+n.mean+n.cov
  ## Return parameters with AIC/BIC
  structure(list(K=K,
                 pars=pars,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams),
            class="mvnhmm")
}



#' @rdname mvnHMM
#' @export
gmvnHMM <- function(y,cl,gr,
                    common.transition=FALSE,
                    min.iters=10,max.iters=50,tol=1.0E-3,
                    verbose=interactive()) {

  K <- max(cl)
  ys <- split.data.frame(y,gr)
  cls <- split(cl,gr)
  pars <- mapply(initHMM,y=ys,cl=cls,
                 MoreArgs=list(K=K),
                 SIMPLIFY=FALSE)
  pars <- initGroup(K,pars)$pars

  ## Weights for common transitions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    p <- Q0 <- 0
    for(g in seq_along(ys)) {
      ## Fit HMM to this group
      pars[[g]] <- hmmEMStep(K,ys[[g]],pars[[g]])
      p <- p+ws[g]*pars[[g]]$p
      Q0 <- Q0+ws[g]*pars[[g]]$Q0
    }
    Q <- Q0/rowSums(Q0)

    ## Enforce common transition probabilities
    if(common.transition) {
      for(g in seq_along(ys)) {
        pars[[g]]$p <- p
        pars[[g]]$Q0 <- Q0
        pars[[g]]$Q <- Q
      }
    }

    ## Total log likelihood
    logL <- sum(sapply(pars,"[[","logL"))

    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- gmvnEMStep(K,ys,pars)
  }
  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.prior <- (if(common.transition) 1 else n.grp)*(K-1)
  n.trans <- (if(common.transition) 1 else n.grp)*K*(K-1)
  n.mean <- n.grp*K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.prior+n.trans+n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  structure(list(pars=pars,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams,
                 common.transition=common.transition),
            class="gmvnhmm")
}


#' @rdname mvnHMM
#' @export
grmvnHMM <- function(y,cl,gr,
                     common.transition=FALSE,
                     min.iters=10,max.iters=100,tol=1.0E-3,
                     verbose=interactive()) {

  K <- max(cl)
  ys <- split(y,gr)
  cls <- split(cl,gr)
  pars <- mapply(initHMM,y=ys,cl=cls,
                 MoreArgs=list(K=K),
                 SIMPLIFY=FALSE)
  fit <- initGroup(K,pars)
  pars <- fit$pars
  muv <- fit$muv

  ## Weights for common transitions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters || (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    p <- Q0 <- 0
    for(g in seq_along(ys)) {
      ## Fit HMM to this group
      pars[[g]] <- hmmEMStep(K,ys[[g]],pars[[g]])
      p <- p+ws[g]*pars[[g]]$p
      Q0 <- Q0+ws[g]*pars[[g]]$Q0
    }
    Q <- Q0/rowSums(Q0)

    ## Enforce common transition probabilities
    if(common.transition) {
      for(g in seq_along(ys)) {
        pars[[g]]$p <- p
        pars[[g]]$Q0 <- Q0
        pars[[g]]$Q <- Q
      }
    }

    ## Total log likelihood
    logL <- 0
    for(g in seq_along(ys)) {
      logL <- logL + pars[[g]]$logL
      for(k in 1:K)
        logL <- logL+dmvnorm(pars[[g]]$mvn[[k]]$mu,muv[[k]]$mu,muv[[k]]$U,log=T)
    }
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means, random effects and covariances
    fit <- grmvnEMStep(K,ys,pars,muv)
    pars <- fit$pars
    muv <- fit$muv
  }
  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.prior <- (if(common.transition) 1 else n.grp)*(K-1)
  n.trans <- (if(common.transition) 1 else n.grp)*K*(K-1)
  n.mean <- K*q
  n.cov <- 2*K*q*(q+1)/2
  nparams <- n.prior+n.trans+n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  structure(list(pars=pars,
                 muv=muv,
                 logL=logL,
                 AIC=-2*logL+2*nparams,
                 BIC=-2*logL+log(nrow(y))*nparams,
                 common.transition=common.transition),
            class="grmvnhmm")
}




## Lots of print methods.

##' @export
print.mvnmix <- function(x,...) {
  cat("Normal Mixture Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.gmvnmix <- function(x,...) {
  cat("Grouped Normal Mixture Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.grmvnmix <- function(x,...) {
  cat("Grouped Random Normal Mixture Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.mvnhmm <- function(x,...) {
  cat("Normal Hidden Markov Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.gmvnhmm <- function(x,...) {
  cat("Grouped Normal Hidden Markov Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.grmvnhmm <- function(x,...) {
  cat("Grouped Random Normal Hidden Markov Model\n")
  print(data.frame(Components=x$K,`log L`=x$logL,AIC=x$AIC,BIC=x$BIC,check.names=F),row.names="")
}

##' @export
print.hmmpars <- function(x,...) {
  cat("Hidden Markov Model ",x$K," States\n\n")
  cat("Prior probability\n")
  print(x$p)
  cat("Transition Probabilities\n")
  print(x$Q)
  for(k in 1:x$K) {
    cat("\nComponent ",k,"\nMean\n")
    print(x$mvn[[k]]$mu)
    cat("\nVariance\n")
    print(x$mvn[[k]]$Sigma)
  }
}

##' @export
print.mixpars <- function(x,...) {
  cat("Normal Mixture: ",x$K," Components\n\n")
  cat("Mixing fractions\n")
  print(x$p)
  for(k in 1:x$K) {
    cat("\nComponent ",k,"\nMean\n")
    print(x$mvn[[k]]$mu)
    cat("\nVariance\n")
    print(x$mvn[[k]]$Sigma)
  }
}

##' @export
print.rcpars <- function(x,...) {
  cat("Random Components Model\n")
  for(k in seq_along(x)) {
    cat("\nComponent ",k,"\nPopulation Mean\n")
    print(x[[k]]$mu)
    cat("\nBetween Group Variance\n")
    print(x[[k]]$U)
    cat("\nWithin Group Variance\n")
    print(x[[k]]$V)
  }
}






##' Fit multivariate Normal 2 State Hidden Markov models by EM.
##'
##' These functions fit multivariate Normal 2 state hidden Markov
##' models to sequences of observations, where the transition
##' probabilities are governed by logistic regression. \code{mvnHMM2}
##' fits a hidden Markov model to a single sequence of
##' observations. \code{gmvnHMM2} and \code{grmvnHMM2} fit separate
##' Markov models to several groups (sequences) of
##' observations. \code{gmvnHMM2} fits a hidden Markov model to each
##' group so that each state has a different mean across groups, but a
##' common covariance. \code{grmvnHMM2} constrains the means of the
##' states to be Normally distributed across groups.
##'
##'
##' @title Multivariate Normal Hidden Markov Model
##' @param y the sequence of observations
##' @param cl an integer vector allocating observations to classes
##' @param gr an integer vector allocating observations to groups
##' @param formula1 formula for the logistic model relating the transition from state 1 to state 2 to the covariates
##' @param formula2 formula for the logistic model relating the transition from state 2 to state 1 to the covariates
##' @param data a dataframe of covariates
##' @param min.iters minimum number of EM iterations
##' @param max.iters maximum number of EM iterations
##' @param tol tolerance for the log likelihood
##' @param verbose should the log likelihood be reported.
##' @return the fitted model
##' @export
mvnHMM2 <- function(y,cl,
                    formula1,formula2,data,
                    min.iters=10,max.iters=50,tol=1.0E-3,
                    verbose=interactive()) {

  K <- 2
  n <- nrow(y)
  pars <- initHMM2(y,cl,formula1,formula2,data)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters ||
        (iter < max.iters && abs(logL-logL0) > tol)) {
    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Fit HMM to this group
    pars <- hmm2EMStep(K,y,pars,formula1,formula2,data)
    logL <- pars$logL
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- mvnEMStep(K,y,pars)
  }
  ## Number of parameters
  q <- ncol(y)
  n.prior <- K-1
  n.beta <- length(pars$beta1)+length(pars$beta2)
  n.mean <- K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.prior+n.beta+n.mean+n.cov
  ## Return parameters with AIC/BIC
  pars$AIC=-2*logL+2*nparams
  pars$BIC=-2*logL+log(nrow(y))*nparams
  pars
}


#' @rdname mvnHMM2
#' @export
gmvnHMM2 <- function(y,cl,gr,
                     formula1,formula2,data,
                     min.iters=10,max.iters=50,tol=1.0E-3,
                     verbose=interactive()) {

  K <- 2
  ys <- split.data.frame(y,gr)
  datas <- split.data.frame(data,gr)
  cls <- split(cl,gr)
  pars <- mapply(initHMM2,y=ys,cl=cls,data=datas,
                 MoreArgs=list(formula1=formula1,formula2=formula2),
                 SIMPLIFY=FALSE)
  pars <- initGroup(K,pars)$pars

  ## Weights for common transitions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters ||
        (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    for(g in seq_along(ys)) {
      ## Fit HMM to this group
      pars[[g]] <- hmm2EMStep(K,ys[[g]],pars[[g]],formula1,formula2,datas[[g]])
    }

    ## Total log likelihood
    logL <- sum(sapply(pars,"[[","logL"))
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means and covariances
    pars <- gmvnEMStep(K,ys,pars)

  }
  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.prior <- (K-1)
  n.beta <- sum(sapply(pars,function(p) length(p$beta1)+length(p$beta2)))
  n.mean <- n.grp*K*q
  n.cov <- K*q*(q+1)/2
  nparams <- n.prior+n.beta+n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  list(pars=pars,
       logL=logL,
       AIC=-2*logL+2*nparams,
       BIC=-2*logL+log(nrow(y))*nparams)
}


#' @rdname mvnHMM2
#' @export
grmvnHMM2 <- function(y,cl,gr,
                      formula1,formula2,data,
                      min.iters=10,max.iters=100,tol=1.0E-3,
                      verbose=interactive()) {

  K <- 2
  ys <- split.data.frame(y,gr)
  datas <- split.data.frame(data,gr)
  cls <- split(cl,gr)
  pars <- mapply(initHMM2,y=ys,cl=cls,data=datas,
                 MoreArgs=list(formula1=formula1,formula2=formula2),
                 SIMPLIFY=FALSE)
  fit <- initGroup(K,pars)
  pars <- fit$pars
  muv <- fit$muv

  ## Weights for common transitions
  ws <- sapply(ys,nrow)
  ws <- ws/sum(ws)

  logL0 <- logL <- -Inf
  iter <- 0
  str <- ""
  ## EM iteration
  while(iter < min.iters ||
        (iter < max.iters && abs(logL-logL0) > tol)) {

    ## Bookkeeping
    iter <- iter+1
    logL0 <- logL

    ## Update posterior probabilities of class membership
    for(g in seq_along(ys)) {
      ## Fit HMM to this group
      pars[[g]] <- hmm2EMStep(K,ys[[g]],pars[[g]],formula1,formula2,datas[[g]])
    }

    ## Total log likelihood
    logL <- 0
    for(g in seq_along(ys)) {
      logL <- logL + pars[[g]]$logL
      for(k in 1:K)
        logL <- logL+dmvnorm(pars[[g]]$mvn[[k]]$mu,muv[[k]]$mu,muv[[k]]$U,log=T)
    }
    if(verbose) {
      if(nchar(str)) cat(paste(rep("\b",nchar(str)),collapse=""))
      str <- sprintf("Log L: %0.3f",logL)
      cat(str)
      flush.console()
    }

    ## Update means, random effects and covariances
    fit <- grmvnEMStep(K,ys,pars,muv)
    pars <- fit$pars
    muv <- fit$muv
  }
  ## Number of parameters
  q <- ncol(y)
  n.grp <- length(ys)
  n.prior <- (K-1)
  n.beta <- sum(sapply(pars,function(p) length(p$beta1)+length(p$beta2)))
  n.mean <- K*q
  n.cov <- 2*K*q*(q+1)/2
  nparams <- n.prior+n.beta+n.mean+n.cov
  ## Return parameters, logL, AIC, BIC
  list(K=K,pars=pars,muv=muv,
       logL=logL,
       AIC=-2*logL+2*nparams,
       BIC=-2*logL+log(nrow(y))*nparams)
}



