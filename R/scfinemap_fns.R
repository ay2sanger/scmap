#' Create an index for a dataset to enable fast approximate nearest neighbour search
#' 
#' The method is based on product quantization for the cosine distance.
#' Split the training data into M identically sized chunks by genes.
#' Use k-means to find k subcentroids for each group.
#' Assign cluster numbers to each member of the dataset.
#' 
#' @param dat an object of \code{\link[SingleCellExperiment]{SingleCellExperiment}} class
#' @param k number of clusters per group for k-means clustering
#' @param M number of chunks into which the expr matrix is split
#' 
#' @return a list of four objects: 1) a list of matrices containing the subcentroids of each group
#' 2) a matrix containing the subclusters for each cell for each group
#' 3) the value of M
#' 4) the value of k
#' 
#' @name scf_index
#' 
#' @importFrom SummarizedExperiment rowData rowData<-
#' @importFrom SingleCellExperiment logcounts logcounts<-
#' @importFrom stats kmeans
#' 
#' @useDynLib scmap
#' @importFrom Rcpp sourceCpp

scf_index <- function(dat, M=100, k=NULL) {
  
  # if k is unspecified, we assign it to be the sqrt of the number of cells in the dataset
  if (is.null(k)) {
    k <- floor(sqrt(dim(dat)[2]))
  }
  
  # perform feature selection for 1000 cells
  new <- scmap::getFeatures(dat, n_features = 1000)
  indices <- which(rowData(new)$scmap_features)
  rownames(dat) <- rowData(dat)$feature_symbol
  dat <- logcounts(dat)[indices,]
  rows <- as.integer(dim(dat)[1])
  cols <- as.integer(dim(dat)[2])
  
  #normalize dataset to perform k-means by cosine similarity
  norm_dat <- normalise(dat)
  chunksize <- floor(rows/M)
  
  chunks <- list()
  for (i in 1:M) {
    chunks[[i]] <- norm_dat[((i-1)*chunksize+1):(i*chunksize),]
  }
  
  subcentroids <- list()
  subclusters <- list()
  km <- list()
  
  #perform k-means for each chunk
  for (m in 1:M) {
    tryCatch({
      # invisible(capture.output(km[[m]] <- kmeanscpp(chunks[[m]], k)))
      # subcentroids[[m]] <- as.matrix(km[[m]]$centers)
      # subclusters[[m]] <- as.vector(km[[m]]$result)
      km[[m]] <- kmeans(x = t(chunks[[m]]), centers = k, iter.max = 50)
      subclusters[[m]] <- km[[m]]$cluster
      subcentroids[[m]] <- t(km[[m]]$centers)
    }, error = function(e) {
      return(NULL)
    })
  }
  
  subcentroids <- lapply(subcentroids, normalise)
  for (m in 1:M) {
    rownames(subcentroids[[m]]) <- rownames(dat[((m-1)*chunksize+1):(m*chunksize),])
  }
  subclusters <- do.call(rbind, subclusters)
  l <- list()
  l[[1]] <- subcentroids
  l[[2]] <- subclusters
  l[[3]] <- k
  l[[4]] <- M
  return(l)
}

#' For each cell in a query dataset, we search for the nearest neighbours by cosine distance
#' within a collection of reference datasets.
#' 
#' @param list_dat list of index objects each coming from the output of scf_index
#' @param query_dat an object of \code{\link[SingleCellExperiment]{SingleCellExperiment}} class
#' @param w a positive integer specifying the number of nearest neighbours to find
#' 
#' @return a list of 3 objects: 
#' 1) a matrix with the closest w neighbours by cell number of each query cell stored by column
#' 2) a matrix of integers giving the reference datasets from which the above cells came from
#' 3) a matrix with the cosine similarities corresponding to each of the nearest neighbours
#' 
#' @name mult_search
#' 
#' @importFrom SummarizedExperiment rowData rowData<- colData colData<-
#' @importFrom SingleCellExperiment logcounts logcounts<-
#' 
#' @useDynLib scmap
#' @importFrom Rcpp sourceCpp

mult_search <- function(list_dat, query_dat, w) {
  features_query <- rowData(query_dat)$feature_symbol
  exprs_query <- logcounts(query_dat)
  num_cells <- dim(exprs_query)[2]
  rownames(exprs_query) <- rowData(query_dat)$feature_symbol
  print(sprintf("Searching reference dataset %i...", 1))
  # evaluate first dataset on the reference list
  ref <- list_dat[[1]]
  subcentroids <- ref[[1]]
  subclusters <- ref[[2]]
  query_chunks <- list()
  k <- ref[[3]]
  M <- ref[[4]]
  SqNorm <- numeric(dim(exprs_query)[2])
  
  for (m in 1:M) {
    subcentroids_chunk <- subcentroids[[m]]
    features_chunk <- rownames(subcentroids_chunk)
    common_features <- intersect(features_chunk, features_query)
    if (length(common_features)==0) {
      # change to a more memory-efficient method later?
      query_chunks[[m]] <- matrix(numeric(num_cells), 1, num_cells)
      subcentroids[[m]] <- matrix(numeric(k), 1, k)
    } else {
      # reduce both the query and the reference to just the rows corr. to common features
      common_features <- sort(common_features)
      subcentroids[[m]] <- subcentroids_chunk[rownames(subcentroids_chunk) %in% common_features, , drop = FALSE]
      query_chunks[[m]] <- exprs_query[rownames(exprs_query) %in% common_features, , drop = FALSE]
      if (length(common_features) > 1) {
        subcentroids[[m]] <- subcentroids[[m]][order(rownames(subcentroids[[m]])), ]
        query_chunks[[m]] <- query_chunks[[m]][order(rownames(query_chunks[[m]])), ]
      }
      # find the squared Euclidean norm of every query after selecting features
      SqNorm <- SqNorm + EuclSqNorm(query_chunks[[m]])
    }
  }
  # compute the w nearest neighbours and their similarities to the queries
  res = NNfirst(w, k, subcentroids, subclusters, query_chunks, M, SqNorm)
  
  # evaluate the other datasets in the reference list
  if (length(list_dat)>1) {
    for (dat_num in 2:length(list_dat)) {
      print(sprintf("Searching reference dataset %i...", dat_num))
      ref <- list_dat[[dat_num]]
      subcentroids <- ref[[1]]
      subclusters <- ref[[2]]
      query_chunks <- list()
      k <- ref[[3]]
      M <- ref[[4]]
      SqNorm <- numeric(dim(exprs_query)[2])
      for (m in 1:M) {
        subcentroids_chunk <- subcentroids[[m]]
        features_chunk <- rownames(subcentroids_chunk)
        common_features <- intersect(features_chunk, features_query)
        
        if (length(common_features)==0) {
          # change to a more memory-efficient method later?
          query_chunks[[m]] <- matrix(numeric(num_cells), 1, num_cells)
          subcentroids[[m]] <- matrix(numeric(k), 1, k)
        } else {
          common_features <- sort(common_features)
          subcentroids[[m]] <- subcentroids_chunk[rownames(subcentroids_chunk) %in% common_features, , drop = FALSE]
          query_chunks[[m]] <- exprs_query[rownames(exprs_query) %in% common_features, , drop = FALSE]
          if (length(common_features) > 1) {
            subcentroids[[m]] <- subcentroids[[m]][order(rownames(subcentroids[[m]])), ]
            query_chunks[[m]] <- query_chunks[[m]][order(rownames(query_chunks[[m]])), ]
          }
          # find the squared Euclidean norm of every query after selecting features
          SqNorm <- SqNorm + EuclSqNorm(query_chunks[[m]])
        }
      }
      # takes the current best cells and distances as input arguments and updates them
      res = NNmult(w, k, subcentroids, subclusters, query_chunks, M, SqNorm, res$cells, res$distances, res$dataset_inds, dat_num)
    }
  }
  for (i in 1:3) {
    colnames(res[[i]]) <- colnames(exprs_query)
  }
  return(res)
}

#' Approximate k-NN cell-type classification using scfinemap
#' 
#' Each cell in the query dataset is assigned a cell-type if the similarity between its
#' nearest neighbour exceeds a threshold AND its w nearest neighbours have the 
#' same cell-type. 
#' 
#' @param ref an object of \code{\link[SingleCellExperiment]{SingleCellExperiment}} class
#' @param query_dat an object of \code{\link[SingleCellExperiment]{SingleCellExperiment}} class
#' @param ref_index the output of scf_index with ref as its input. 
#' @param w an integer specifying the number of nearest neighbours to find
#' @param thres the threshold which the maximum similarity between the query and a reference cell must exceed
#' for the cell-type to be assigned
#' 
#' @return The query dataset with the predicted labels attached to colData(query_dat)$cell_type1
#' 
#' @name scf_celltype
#' 
#' @importFrom SummarizedExperiment rowData rowData<- colData colData<-
#' 
#' @useDynLib scmap
#' @importFrom Rcpp sourceCpp
scf_celltype <- function(ref, query_dat, ref_index = NULL, w=3, thres = 0.5) {
  # if the reference index is not given, then it will calculated here
  if (is.null(ref_index)) {
    ref_index <- scf_index(ref)
  }
  
  # compute the w nearest neighbours for each cell
  list_dat <- list()
  list_dat[[1]] <- ref_index
  res <- mult_search(list_dat, query_dat, w)
  
  labs_orig <- as.character(colData(query_dat)$cell_type1)
  query_size <- length(labs_orig)
  labs_new <- character(query_size)
  
  for (i in 1:query_size) {
    celltypes <- numeric(w)
    for (j in 1:w) {
      celltypes[j] <- as.character(colData(ref)$cell_type1[res$cell[j,i]])
    }
    # only assign the cell-type if the similarity exceeds the threshold
    # and the w nearest neighbours are the same cell-type
    if (max(res$distances[,i])>thres & length(unique(celltypes))==1) {
      labs_new[i] <- as.character(colData(ref)$cell_type1[res$cell[1, i]])
    } else {
      labs_new[i] <- "unassigned"
    }
  }
  colData(query_dat)$cell_type1 <- labs_new
  return(query_dat)
}